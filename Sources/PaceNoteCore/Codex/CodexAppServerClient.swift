import Foundation

public struct CodexAppServerConfiguration: Sendable {
    public let executableURL: URL
    public let expectedCodexHome: URL
    public let versionPolicy: CodexVersionPolicy
    public let requestTimeout: Duration
    public let clientName: String
    public let clientTitle: String
    public let clientVersion: String
    public let serviceName: String
    public let permissionProfileID: String
    public let processArguments: [String]
    public let processEnvironment: [String: String]?

    public init(
        executableURL: URL = URL(
            fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"
        ),
        expectedCodexHome: URL,
        versionPolicy: CodexVersionPolicy = .supported,
        requestTimeout: Duration = .seconds(15),
        clientName: String = "pacenote",
        clientTitle: String = "ChirpCue",
        clientVersion: String,
        serviceName: String = "pacenote",
        permissionProfileID: String = ":read-only",
        processArguments: [String] = ["app-server", "--stdio"],
        processEnvironment: [String: String]? = nil
    ) {
        self.executableURL = executableURL
        self.expectedCodexHome = expectedCodexHome
        self.versionPolicy = versionPolicy
        self.requestTimeout = requestTimeout
        self.clientName = clientName
        self.clientTitle = clientTitle
        self.clientVersion = clientVersion
        self.serviceName = serviceName
        self.permissionProfileID = permissionProfileID
        self.processArguments = processArguments
        self.processEnvironment = processEnvironment
    }
}

public actor CodexAppServerClient {
    private enum State: Equatable {
        case new
        case initializing
        case ready
        case failed
        case stopping
        case stopped
    }

    private struct TurnKey: Hashable, Sendable {
        let threadID: String
        let turnID: String
    }

    private let transport: any CodexRPCTransporting
    private let configuration: CodexAppServerConfiguration
    public nonisolated let binaryVersion: CodexBinaryVersion
    public nonisolated let runtimeCapabilities: CodexRuntimeCapabilities

    private var state = State.new
    private var eventTask: Task<Void, Never>?
    private var notificationContinuations: [UUID: AsyncStream<CodexServerNotification>.Continuation] = [:]
    private var pendingTurnThreads: Set<String> = []
    private var bufferedTurnNotifications: [String: [CodexServerNotification]] = [:]
    private var turnContinuations: [TurnKey: AsyncThrowingStream<CodexTurnEvent, any Error>.Continuation] = [:]
    private var realtimeContinuations: [String: AsyncThrowingStream<CodexRealtimeEvent, any Error>.Continuation] = [:]

    init(
        transport: any CodexRPCTransporting,
        configuration: CodexAppServerConfiguration,
        binaryVersion: CodexBinaryVersion,
        runtimeCapabilities: CodexRuntimeCapabilities = .none
    ) {
        self.transport = transport
        self.configuration = configuration
        self.binaryVersion = binaryVersion
        self.runtimeCapabilities = runtimeCapabilities
    }

    public static func connect(
        configuration: CodexAppServerConfiguration
    ) async throws -> CodexAppServerClient {
        try CodexBinaryAuthenticityValidator.validate(configuration.executableURL)
        let version = try await CodexBinaryInspector.inspect(
            executableURL: configuration.executableURL,
            environment: configuration.processEnvironment
        )
        try configuration.versionPolicy.validate(version)
        let runtimeCapabilities = await CodexRuntimeCapabilityInspector.probe(
            executableURL: configuration.executableURL,
            environment: configuration.processEnvironment
        )

        let transport = CodexProcessTransport(
            configuration: .init(
                executableURL: configuration.executableURL,
                requestTimeout: configuration.requestTimeout,
                arguments: configuration.processArguments,
                environment: configuration.processEnvironment,
                postLaunchValidator: { processID, executableURL in
                    try SpawnedProcessAttestation.validateCodex(
                        processID: processID,
                        executableURL: executableURL
                    )
                }
            )
        )
        let client = CodexAppServerClient(
            transport: transport,
            configuration: configuration,
            binaryVersion: version,
            runtimeCapabilities: runtimeCapabilities
        )
        try await client.initialize()
        return client
    }

    func initialize() async throws {
        guard state == .new else {
            throw state == .ready
                ? CodexClientError.alreadyInitialized
                : CodexClientError.transportUnavailable
        }
        state = .initializing

        do {
            try await transport.start()
            let events = await transport.events()
            eventTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    await self.handleTransportEvent(event)
                }
            }

            let result: CodexInitializeResult = try await call(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": .string(configuration.clientName),
                        "title": .string(configuration.clientTitle),
                        "version": .string(configuration.clientVersion),
                    ],
                    "capabilities": [
                        "experimentalApi": true,
                        "requestAttestation": false,
                    ],
                ]
            )
            guard result.platformOs == "macos", result.platformFamily == "unix" else {
                throw CodexClientError.unsupportedPlatform
            }
            guard
                Self.matchesExpectedCodexHome(
                    result.codexHome,
                    expected: configuration.expectedCodexHome
                )
            else {
                throw CodexClientError.profileMismatch
            }

            try await transport.sendNotification(method: "initialized", params: nil)
            state = .ready
        } catch {
            state = .failed
            eventTask?.cancel()
            await transport.stop()
            throw Self.safe(error)
        }
    }

    public func account(refreshToken: Bool = false) async throws -> CodexAccountReadResult {
        try requireReady()
        return try await call(
            method: "account/read",
            params: ["refreshToken": .bool(refreshToken)]
        )
    }

    public func startChatGPTLogin(
        useHostedLoginSuccessPage: Bool = true
    ) async throws -> CodexChatGPTLogin {
        try requireReady()
        let result: CodexChatGPTLogin = try await call(
            method: "account/login/start",
            params: [
                "type": "chatgpt",
                "useHostedLoginSuccessPage": .bool(useHostedLoginSuccessPage),
                "appBrand": "chatgpt",
            ]
        )
        guard result.type == "chatgpt",
            !result.loginId.isEmpty,
            let authURL = URL(string: result.authUrl),
            CodexChatGPTLoginURLPolicy.permits(authURL)
        else {
            throw CodexClientError.invalidResponse(method: "account/login/start")
        }
        return result
    }

    public func cancelChatGPTLogin(loginID: String) async throws {
        try requireReady()
        guard !loginID.isEmpty else {
            throw CodexClientError.invalidResponse(method: "account/login/cancel")
        }
        let result = try await transport.request(
            method: "account/login/cancel",
            params: ["loginId": .string(loginID)]
        )
        guard let status = result["status"]?.stringValue,
            status == "canceled" || status == "notFound"
        else {
            throw CodexClientError.invalidResponse(method: "account/login/cancel")
        }
    }

    public func logout() async throws {
        try requireReady()
        _ = try await transport.request(method: "account/logout", params: nil)
    }

    public func listModels(includeHidden: Bool = false) async throws -> [CodexModel] {
        try requireReady()
        var models: [CodexModel] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        for _ in 0..<20 {
            var params: [String: JSONValue] = [
                "limit": 100,
                "includeHidden": .bool(includeHidden),
            ]
            if let cursor { params["cursor"] = .string(cursor) }
            let page: CodexModelListPage = try await call(
                method: "model/list",
                params: .object(params)
            )
            models.append(contentsOf: page.data)
            guard let next = page.nextCursor else { return models }
            guard seenCursors.insert(next).inserted else {
                throw CodexClientError.invalidResponse(method: "model/list")
            }
            cursor = next
        }
        throw CodexClientError.invalidResponse(method: "model/list")
    }

    public func listThreadIDs(cwd: String) async throws -> [String] {
        try requireReady()
        try Self.requireAbsolutePath(cwd)
        var identifiers: [String] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        for _ in 0..<20 {
            var params: [String: JSONValue] = [
                "limit": 100,
                "cwd": .string(cwd),
                "sourceKinds": [.string("appServer")],
                "archived": false,
            ]
            if let cursor { params["cursor"] = .string(cursor) }
            let page: CodexThreadListPage = try await call(
                method: "thread/list",
                params: .object(params)
            )
            guard page.data.allSatisfy({ !$0.id.isEmpty }) else {
                throw CodexClientError.invalidResponse(method: "thread/list")
            }
            identifiers.append(contentsOf: page.data.map(\.id))
            guard let next = page.nextCursor else { return identifiers }
            guard seenCursors.insert(next).inserted else {
                throw CodexClientError.invalidResponse(method: "thread/list")
            }
            cursor = next
        }
        throw CodexClientError.invalidResponse(method: "thread/list")
    }

    public func rateLimits() async throws -> CodexRateLimitsResult {
        try requireReady()
        return try await call(method: "account/rateLimits/read", params: nil)
    }

    public func listPermissionProfiles(cwd: String) async throws -> [CodexPermissionProfile] {
        try requireReady()
        try Self.requireAbsolutePath(cwd)

        var profiles: [CodexPermissionProfile] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        for _ in 0..<20 {
            var params: [String: JSONValue] = ["cwd": .string(cwd), "limit": 100]
            if let cursor { params["cursor"] = .string(cursor) }
            let page: CodexPermissionProfilePage = try await call(
                method: "permissionProfile/list",
                params: .object(params)
            )
            profiles.append(contentsOf: page.data)
            guard let next = page.nextCursor else { return profiles }
            guard seenCursors.insert(next).inserted else {
                throw CodexClientError.invalidResponse(method: "permissionProfile/list")
            }
            cursor = next
        }
        throw CodexClientError.invalidResponse(method: "permissionProfile/list")
    }

    public func listSkills(cwds: [String], forceReload: Bool = false) async throws -> CodexSkillsResult {
        try requireReady()
        guard !cwds.isEmpty else { throw CodexClientError.missingCapability("skills/list.cwd") }
        for cwd in cwds { try Self.requireAbsolutePath(cwd) }
        return try await call(
            method: "skills/list",
            params: [
                "cwds": .array(cwds.map(JSONValue.string)),
                "forceReload": .bool(forceReload),
            ]
        )
    }

    public func setSkillExtraRoots(_ roots: [String]) async throws {
        try requireReady()
        for root in roots { try Self.requireAbsolutePath(root) }
        _ = try await transport.request(
            method: "skills/extraRoots/set",
            params: ["extraRoots": .array(roots.map(JSONValue.string))]
        )
    }

    public func setSkillEnabled(
        name: String,
        path: String,
        enabled: Bool
    ) async throws -> CodexSkillsConfigWriteResult {
        try requireReady()
        guard !name.isEmpty else { throw CodexClientError.threadInvariantFailed }
        try Self.requireAbsolutePath(path)
        // The v2 protocol exposes name and path as alternative selectors. Current Codex builds
        // reject requests that supply both, so use the exact absolute path to avoid name
        // collisions and to keep ChirpCue's allowlist binding deterministic.
        return try await call(
            method: "skills/config/write",
            params: [
                "path": .string(path),
                "enabled": .bool(enabled),
            ]
        )
    }

    public func verifyCapabilities(cwd: String) async throws -> CodexCapabilitySnapshot {
        // Keep capability discovery serialized. Some Codex app-server builds accept these
        // requests concurrently but then stop answering the first thread/start on that process.
        // Preparation is infrequent, and a deterministic healthy transport matters more than
        // saving a few milliseconds here.
        let models = try await listModels()
        let profiles = try await listPermissionProfiles(cwd: cwd)
        let skills = try await listSkills(cwds: [cwd])
        guard !models.isEmpty else { throw CodexClientError.missingCapability("model/list") }
        guard
            profiles.contains(where: {
                $0.id == configuration.permissionProfileID && $0.allowed
            })
        else {
            throw CodexClientError.permissionProfileUnavailable(
                configuration.permissionProfileID
            )
        }
        return CodexCapabilitySnapshot(
            models: models,
            permissionProfiles: profiles,
            skills: skills.data
        )
    }

    public func createPersistentBase(
        cwd: String,
        runtimeWorkspaceRoots: [String],
        model: String,
        baseInstructions: String? = nil
    ) async throws -> CodexBaseThread {
        do {
            return try await createPersistentBase(
                cwd: cwd,
                runtimeWorkspaceRoots: runtimeWorkspaceRoots,
                model: model,
                baseInstructions: baseInstructions,
                onCreated: { _ in }
            )
        } catch let failure as CodexCreatedThreadFailure {
            _ = try? await transport.request(
                method: "thread/delete",
                params: ["threadId": .string(failure.threadID)]
            )
            throw Self.error(for: failure.cause)
        }
    }

    public func createPersistentBase(
        cwd: String,
        runtimeWorkspaceRoots: [String],
        model: String,
        baseInstructions: String?,
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexBaseThread {
        try requireReady()
        try Self.requireAbsolutePath(cwd)
        guard !runtimeWorkspaceRoots.isEmpty else {
            throw CodexClientError.threadInvariantFailed
        }
        for root in runtimeWorkspaceRoots { try Self.requireAbsolutePath(root) }

        var params: [String: JSONValue] = [
            "model": .string(model),
            "cwd": .string(cwd),
            "runtimeWorkspaceRoots": .array(runtimeWorkspaceRoots.map(JSONValue.string)),
            "approvalPolicy": "never",
            "permissions": .string(configuration.permissionProfileID),
            "ephemeral": false,
            "serviceName": .string(configuration.serviceName),
        ]
        if let baseInstructions, !baseInstructions.isEmpty {
            params["baseInstructions"] = .string(baseInstructions)
        }

        let result: CodexThreadConfigurationResult = try await call(
            method: "thread/start",
            params: .object(params)
        )
        do {
            try await onCreated(result.thread.id)
        } catch {
            _ = try? await transport.request(
                method: "thread/delete",
                params: ["threadId": .string(result.thread.id)]
            )
            throw error
        }
        do {
            try validateThreadResult(
                result,
                expectedEphemeral: false,
                expectedParent: nil,
                expectedCwd: cwd,
                expectedWorkspaceRoots: runtimeWorkspaceRoots
            )
            // A fresh thread has no rollout and cannot be forked. A nonempty, non-sensitive
            // marker materializes it without running a model.
            _ = try await transport.request(
                method: "thread/inject_items",
                params: [
                    "threadId": .string(result.thread.id),
                    "items": [
                        [
                            "type": "message",
                            "role": "assistant",
                            "content": [
                                [
                                    "type": "output_text",
                                    "text": "ChirpCue evidence context initialized.",
                                ]
                            ],
                        ]
                    ],
                ]
            )
        } catch {
            throw CodexCreatedThreadFailure(
                threadID: result.thread.id,
                cause: Self.createdThreadFailureCause(for: error)
            )
        }

        return CodexBaseThread(
            id: result.thread.id,
            model: result.model,
            permissionProfileID: configuration.permissionProfileID,
            cwd: result.cwd,
            runtimeWorkspaceRoots: result.runtimeWorkspaceRoots,
            instructionSources: result.instructionSources
        )
    }

    public func forkEphemeral(
        from base: CodexBaseThread,
        model: String? = nil
    ) async throws -> CodexEphemeralThread {
        do {
            return try await forkEphemeral(
                from: base,
                model: model,
                onCreated: { _ in }
            )
        } catch let failure as CodexCreatedThreadFailure {
            _ = try? await transport.request(
                method: "thread/delete",
                params: ["threadId": .string(failure.threadID)]
            )
            state = .failed
            await transport.stop()
            throw Self.error(for: failure.cause)
        }
    }

    public func forkEphemeral(
        from base: CodexBaseThread,
        model: String?,
        onCreated: @Sendable (String) async throws -> Void
    ) async throws -> CodexEphemeralThread {
        try requireReady()
        guard base.permissionProfileID == configuration.permissionProfileID else {
            throw CodexClientError.permissionProfileMismatch
        }

        var params: [String: JSONValue] = [
            "threadId": .string(base.id),
            "ephemeral": true,
            "excludeTurns": true,
            "approvalPolicy": "never",
            // Repeat the profile explicitly. This is not reliably inherited by forks.
            "permissions": .string(configuration.permissionProfileID),
            // Current app-server versions retain only the primary cwd unless every sealed
            // read-only root is repeated on the fork. A dropped packaged-skill root would make
            // the fork fail the same workspace invariant that protects meeting turns.
            "runtimeWorkspaceRoots": .array(base.runtimeWorkspaceRoots.map(JSONValue.string)),
        ]
        if let model { params["model"] = .string(model) }

        let result: CodexThreadConfigurationResult = try await call(
            method: "thread/fork",
            params: .object(params)
        )
        do {
            try await onCreated(result.thread.id)
        } catch {
            _ = try? await transport.request(
                method: "thread/delete",
                params: ["threadId": .string(result.thread.id)]
            )
            throw error
        }
        do {
            try validateThreadResult(
                result,
                expectedEphemeral: true,
                expectedParent: base.id,
                expectedCwd: base.cwd,
                expectedWorkspaceRoots: base.runtimeWorkspaceRoots
            )
        } catch {
            throw CodexCreatedThreadFailure(
                threadID: result.thread.id,
                cause: Self.createdThreadFailureCause(for: error)
            )
        }
        return CodexEphemeralThread(
            id: result.thread.id,
            baseThreadID: base.id,
            model: result.model,
            permissionProfileID: configuration.permissionProfileID,
            cwd: result.cwd,
            runtimeWorkspaceRoots: result.runtimeWorkspaceRoots,
            instructionSources: result.instructionSources
        )
    }

    public func deleteThread(id: String) async throws {
        try requireReady()
        guard !id.isEmpty else { throw CodexClientError.threadInvariantFailed }
        _ = try await transport.request(
            method: "thread/delete",
            params: ["threadId": .string(id)]
        )
    }

    public func startTurn(
        threadID: String,
        text: String,
        model: String? = nil,
        effort: String? = nil,
        outputSchema: JSONValue? = nil,
        skills: [CodexSkillInvocation] = []
    ) async throws -> CodexTurnSession {
        try requireReady()
        guard !threadID.isEmpty,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexClientError.threadInvariantFailed
        }
        guard pendingTurnThreads.insert(threadID).inserted else {
            throw CodexClientError.turnAlreadyStarting
        }

        var input: [JSONValue] = [
            [
                "type": "text",
                "text": .string(text),
                "text_elements": [],
            ]
        ]
        for skill in skills {
            guard !skill.name.isEmpty else { throw CodexClientError.threadInvariantFailed }
            try Self.requireAbsolutePath(skill.path)
        }
        input.append(
            contentsOf: skills.map { skill in
                [
                    "type": "skill",
                    "name": .string(skill.name),
                    "path": .string(skill.path),
                ]
            })

        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(input),
            "approvalPolicy": "never",
            "permissions": .string(configuration.permissionProfileID),
        ]
        if let model { params["model"] = .string(model) }
        if let effort { params["effort"] = .string(effort) }
        if let outputSchema { params["outputSchema"] = outputSchema }

        let result: CodexTurnStartResult
        do {
            result = try await call(method: "turn/start", params: .object(params))
        } catch {
            pendingTurnThreads.remove(threadID)
            bufferedTurnNotifications.removeValue(forKey: threadID)
            throw Self.safe(error)
        }

        let key = TurnKey(threadID: threadID, turnID: result.turn.id)
        let pair = AsyncThrowingStream<CodexTurnEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeTurnContinuation(key: key) }
        }
        turnContinuations[key] = pair.continuation
        pendingTurnThreads.remove(threadID)

        let buffered = bufferedTurnNotifications.removeValue(forKey: threadID) ?? []
        for notification in buffered {
            guard Self.turnID(in: notification) == result.turn.id else { continue }
            deliver(notification, to: key)
        }

        return CodexTurnSession(
            threadID: threadID,
            turnID: result.turn.id,
            events: pair.stream
        )
    }

    public func interruptTurn(threadID: String, turnID: String) async throws {
        try requireReady()
        _ = try await transport.request(
            method: "turn/interrupt",
            params: [
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ]
        )
    }

    /// Starts the experimental text-only realtime Quick path when the installed schema proves
    /// the complete V3 surface is present. Otherwise it falls back to an ordinary low-effort turn.
    public func startQuick(
        threadID: String,
        text: String,
        realtimePrompt: String,
        model: String? = nil,
        outputSchema: JSONValue? = nil,
        skills: [CodexSkillInvocation] = []
    ) async throws -> CodexQuickSession {
        if runtimeCapabilities.realtimeTextV3 {
            let session = try await startRealtimeText(
                threadID: threadID,
                prompt: realtimePrompt,
                model: model
            )
            do {
                try await appendRealtimeText(
                    threadID: threadID,
                    text: text,
                    role: .user
                )
            } catch {
                _ = try? await transport.request(
                    method: "thread/realtime/stop",
                    params: ["threadId": .string(threadID)]
                )
                finishRealtime(
                    threadID: threadID,
                    error: Self.safe(error)
                )
                throw Self.safe(error)
            }
            return .realtime(session)
        }

        return .turn(
            try await startTurn(
                threadID: threadID,
                text: text,
                model: model,
                effort: "low",
                outputSchema: outputSchema,
                skills: skills
            )
        )
    }

    public func startRealtimeText(
        threadID: String,
        prompt: String,
        model: String? = nil
    ) async throws -> CodexRealtimeSession {
        try requireReady()
        guard runtimeCapabilities.realtimeTextV3 else {
            throw CodexClientError.missingCapability("thread/realtime/text-v3")
        }
        guard !threadID.isEmpty,
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            realtimeContinuations[threadID] == nil
        else {
            throw CodexClientError.threadInvariantFailed
        }

        let pair = AsyncThrowingStream<CodexRealtimeEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeRealtimeContinuation(threadID: threadID) }
        }
        realtimeContinuations[threadID] = pair.continuation

        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "clientManagedHandoffs": true,
            "outputModality": "text",
            "prompt": .string(prompt),
            "version": "v3",
        ]
        if let model { params["model"] = .string(model) }

        do {
            let response = try await transport.request(
                method: "thread/realtime/start",
                params: .object(params)
            )
            guard response.objectValue != nil else {
                throw CodexClientError.invalidResponse(method: "thread/realtime/start")
            }
        } catch {
            finishRealtime(threadID: threadID, error: Self.safe(error))
            throw Self.safe(error)
        }

        return CodexRealtimeSession(threadID: threadID, events: pair.stream)
    }

    public func appendRealtimeText(
        threadID: String,
        text: String,
        role: CodexRealtimeTextRole
    ) async throws {
        try requireReady()
        guard realtimeContinuations[threadID] != nil,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexClientError.threadInvariantFailed
        }
        _ = try await transport.request(
            method: "thread/realtime/appendText",
            params: [
                "threadId": .string(threadID),
                "text": .string(text),
                "role": .string(role.rawValue),
            ]
        )
    }

    public func stopRealtimeText(threadID: String) async throws {
        try requireReady()
        guard realtimeContinuations[threadID] != nil else {
            throw CodexClientError.threadInvariantFailed
        }
        _ = try await transport.request(
            method: "thread/realtime/stop",
            params: ["threadId": .string(threadID)]
        )
    }

    public func notifications() -> AsyncStream<CodexServerNotification> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            notificationContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeNotificationContinuation(id: id) }
            }
        }
    }

    public func shutdown() async {
        guard state != .stopped, state != .stopping else { return }
        state = .stopping
        eventTask?.cancel()
        finishAllTurns(error: CancellationError())
        finishAllRealtime(error: CancellationError())
        for continuation in notificationContinuations.values { continuation.finish() }
        notificationContinuations.removeAll()
        await transport.stop()
        state = .stopped
    }

    private func call<T: Decodable & Sendable>(
        method: String,
        params: JSONValue?
    ) async throws -> T {
        let value = try await transport.request(method: method, params: params)
        do {
            return try value.decode(T.self)
        } catch let error as CodexClientError {
            throw error
        } catch {
            throw CodexClientError.invalidResponse(method: method)
        }
    }

    private func requireReady() throws {
        guard state == .ready else { throw CodexClientError.notInitialized }
    }

    private func validateThreadResult(
        _ result: CodexThreadConfigurationResult,
        expectedEphemeral: Bool,
        expectedParent: String?,
        expectedCwd: String,
        expectedWorkspaceRoots: [String]
    ) throws {
        guard result.thread.ephemeral == expectedEphemeral,
            result.approvalPolicy.stringValue == "never",
            result.activePermissionProfile?.id == configuration.permissionProfileID,
            Self.canonicalPath(result.cwd) == Self.canonicalPath(expectedCwd),
            result.runtimeWorkspaceRoots.map(Self.canonicalPath)
                == expectedWorkspaceRoots.map(Self.canonicalPath),
            result.instructionSources.allSatisfy({ source in
                source.hasPrefix("/") && !source.contains("\0")
            })
        else {
            throw CodexClientError.permissionProfileMismatch
        }
        if let expectedParent,
            result.thread.forkedFromId != expectedParent
        {
            throw CodexClientError.threadInvariantFailed
        }
    }

    private func handleTransportEvent(_ event: CodexTransportEvent) async {
        switch event {
        case .notification(let notification):
            let publicNotification = Self.redacted(notification)
            for continuation in notificationContinuations.values {
                continuation.yield(publicNotification)
            }
            routeRealtimeNotification(notification)
            routeTurnNotification(notification)

        case .rejectedServerRequest(let method, let threadID, let turnID, let itemID):
            state = .failed
            let error = CodexClientError.serverRequestRejected(
                method: method,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID
            )
            finishAllTurns(error: error)
            finishAllRealtime(error: error)
            await transport.stop()

        case .disconnected:
            guard state != .stopping, state != .stopped else { return }
            state = .failed
            finishAllTurns(error: CodexClientError.transportClosed)
            finishAllRealtime(error: CodexClientError.transportClosed)
        }
    }

    private func routeRealtimeNotification(_ notification: CodexServerNotification) {
        guard notification.method.hasPrefix("thread/realtime/"),
            let threadID = Self.threadID(in: notification),
            let continuation = realtimeContinuations[threadID]
        else {
            return
        }

        switch notification.method {
        case "thread/realtime/started":
            guard let version = notification.params?["version"]?.stringValue,
                version == "v3"
            else {
                finishRealtime(
                    threadID: threadID,
                    error: CodexClientError.invalidResponse(method: notification.method)
                )
                return
            }
            continuation.yield(
                .started(
                    sessionID: notification.params?["realtimeSessionId"]?.stringValue,
                    version: version
                )
            )

        case "thread/realtime/transcript/delta":
            guard let role = notification.params?["role"]?.stringValue,
                let delta = notification.params?["delta"]?.stringValue
            else {
                finishRealtime(
                    threadID: threadID,
                    error: CodexClientError.malformedMessage
                )
                return
            }
            continuation.yield(.transcriptDelta(role: role, delta: delta))

        case "thread/realtime/transcript/done":
            guard let role = notification.params?["role"]?.stringValue,
                let text = notification.params?["text"]?.stringValue
            else {
                finishRealtime(
                    threadID: threadID,
                    error: CodexClientError.malformedMessage
                )
                return
            }
            continuation.yield(.transcriptDone(role: role, text: text))

        case "thread/realtime/itemAdded":
            guard let item = notification.params?["item"] else {
                finishRealtime(
                    threadID: threadID,
                    error: CodexClientError.malformedMessage
                )
                return
            }
            continuation.yield(.itemAdded(item))

        case "thread/realtime/error":
            // The backend message can contain transcript or path material. Never surface it.
            finishRealtime(
                threadID: threadID,
                error: CodexClientError.requestFailed(
                    method: "thread/realtime",
                    code: -32_000
                )
            )

        case "thread/realtime/closed":
            continuation.yield(.closed)
            continuation.finish()
            realtimeContinuations.removeValue(forKey: threadID)

        default:
            break
        }
    }

    private func routeTurnNotification(_ notification: CodexServerNotification) {
        guard let threadID = Self.threadID(in: notification),
            Self.isTurnNotification(notification.method)
        else {
            return
        }

        if let turnID = Self.turnID(in: notification) {
            let key = TurnKey(threadID: threadID, turnID: turnID)
            if turnContinuations[key] != nil {
                deliver(notification, to: key)
                return
            }
        }

        if pendingTurnThreads.contains(threadID) {
            var buffered = bufferedTurnNotifications[threadID] ?? []
            guard buffered.count < 512 else {
                state = .failed
                finishAllTurns(error: CodexClientError.malformedMessage)
                return
            }
            buffered.append(notification)
            bufferedTurnNotifications[threadID] = buffered
        }
    }

    private func deliver(_ notification: CodexServerNotification, to key: TurnKey) {
        guard let continuation = turnContinuations[key] else { return }
        let params = notification.params
        switch notification.method {
        case "item/agentMessage/delta":
            guard let itemID = params?["itemId"]?.stringValue,
                let delta = params?["delta"]?.stringValue
            else {
                continuation.finish(throwing: CodexClientError.malformedMessage)
                turnContinuations.removeValue(forKey: key)
                return
            }
            continuation.yield(.agentMessageDelta(itemID: itemID, delta: delta))

        case "item/completed":
            guard let item = params?["item"] else {
                continuation.finish(throwing: CodexClientError.malformedMessage)
                turnContinuations.removeValue(forKey: key)
                return
            }
            continuation.yield(.itemCompleted(item))

        case "turn/completed":
            guard let status = params?["turn"]?["status"]?.stringValue else {
                continuation.finish(throwing: CodexClientError.malformedMessage)
                turnContinuations.removeValue(forKey: key)
                return
            }
            continuation.yield(.completed(status: status))
            continuation.finish()
            turnContinuations.removeValue(forKey: key)

        default:
            continuation.yield(.notification(method: notification.method, params: params))
        }
    }

    private func finishAllTurns(error: any Error) {
        for continuation in turnContinuations.values {
            continuation.finish(throwing: error)
        }
        turnContinuations.removeAll()
        pendingTurnThreads.removeAll()
        bufferedTurnNotifications.removeAll()
    }

    private func finishRealtime(threadID: String, error: any Error) {
        guard let continuation = realtimeContinuations.removeValue(forKey: threadID) else {
            return
        }
        continuation.finish(throwing: error)
    }

    private func finishAllRealtime(error: any Error) {
        for continuation in realtimeContinuations.values {
            continuation.finish(throwing: error)
        }
        realtimeContinuations.removeAll()
    }

    private func removeTurnContinuation(key: TurnKey) {
        turnContinuations.removeValue(forKey: key)
    }

    private func removeNotificationContinuation(id: UUID) {
        notificationContinuations.removeValue(forKey: id)
    }

    private func removeRealtimeContinuation(threadID: String) {
        realtimeContinuations.removeValue(forKey: threadID)
    }

    private static func isTurnNotification(_ method: String) -> Bool {
        method.hasPrefix("turn/") || method.hasPrefix("item/")
    }

    private static func threadID(in notification: CodexServerNotification) -> String? {
        notification.params?["threadId"]?.stringValue
    }

    private static func turnID(in notification: CodexServerNotification) -> String? {
        if let direct = notification.params?["turnId"]?.stringValue { return direct }
        return notification.params?["turn"]?["id"]?.stringValue
    }

    private static func requireAbsolutePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw CodexClientError.threadInvariantFailed
        }
    }

    private static func matchesExpectedCodexHome(_ actual: String, expected: URL) -> Bool {
        guard expected.isFileURL,
            expected.path.hasPrefix("/"),
            !expected.path.contains("\0"),
            actual.hasPrefix("/"),
            !actual.contains("\0")
        else {
            return false
        }
        let actualURL = URL(fileURLWithPath: actual, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let expectedURL = expected.standardizedFileURL.resolvingSymlinksInPath()
        return actualURL.path == expectedURL.path
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func redacted(
        _ notification: CodexServerNotification
    ) -> CodexServerNotification {
        guard var params = notification.params?.objectValue else { return notification }
        for key in ["error", "message", "reason"] where params[key] != nil {
            params[key] = .string("<redacted>")
        }
        return CodexServerNotification(method: notification.method, params: .object(params))
    }

    private static func safe(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let safe = error as? CodexClientError { return safe }
        return CodexClientError.transportUnavailable
    }

    private static func createdThreadFailureCause(
        for error: any Error
    ) -> CodexCreatedThreadFailureCause {
        if error is CancellationError { return .cancellation }
        return .client((error as? CodexClientError) ?? .transportUnavailable)
    }

    private static func error(for cause: CodexCreatedThreadFailureCause) -> any Error {
        switch cause {
        case .cancellation: CancellationError()
        case .client(let error): error
        }
    }
}
