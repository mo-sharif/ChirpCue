import Foundation
import XCTest

@testable import PaceNoteCore

final class CodexAppServerClientTests: XCTestCase {
    func testWireCodecClassifiesAndRejectsServerRequestsWithoutLeakingPayload() throws {
        let inbound = try CodexWireCodec.decodeLine(Data(CodexFixtures.serverRequest.utf8))
        guard case .serverRequest(let id, let method, let params) = inbound else {
            return XCTFail("Expected a server request.")
        }
        XCTAssertEqual(id, .integer(77))
        XCTAssertEqual(method, "item/commandExecution/requestApproval")
        XCTAssertEqual(params?["threadId"]?.stringValue, "fork-thread")
        XCTAssertEqual(params?["turnId"]?.stringValue, "turn-1")
        XCTAssertEqual(params?["itemId"]?.stringValue, "command-item")

        let rejection = try CodexWireCodec.rejectedServerRequest(id: id)
        XCTAssertEqual(rejection.last, 0x0A)
        let rejectionValue = try JSONDecoder().decode(
            JSONValue.self,
            from: rejection.dropLast()
        )
        XCTAssertEqual(rejectionValue["id"]?.intValue, 77)
        XCTAssertEqual(rejectionValue["error"]?["code"]?.intValue, -32_000)
        XCTAssertNil(rejectionValue["jsonrpc"])

        let errorInbound = try CodexWireCodec.decodeLine(Data(CodexFixtures.serverError.utf8))
        guard case .response(_, _, let payload?) = errorInbound else {
            return XCTFail("Expected an error response.")
        }
        let safeError = CodexClientError.requestFailed(method: "turn/start", code: payload.code)
        XCTAssertFalse(safeError.localizedDescription.contains("/Users/"))
        XCTAssertFalse(safeError.localizedDescription.contains("token-secret"))
    }

    func testVersionParserAndTestedRange() throws {
        let version = try XCTUnwrap(
            CodexBinaryVersion.parse("codex-cli 0.147.0-alpha.1.2\n")
        )
        XCTAssertEqual(version.major, 0)
        XCTAssertEqual(version.minor, 147)
        XCTAssertEqual(version.patch, 0)
        XCTAssertEqual(version.prerelease, "alpha.1.2")
        XCTAssertNoThrow(try CodexVersionPolicy.tested.validate(version))
        XCTAssertThrowsError(
            try CodexVersionPolicy.tested.validate(
                .init(major: 0, minor: 148, patch: 0)
            )
        )
    }

    func testRealtimeCapabilityRequiresTheCompleteGeneratedSchemaSurface() {
        let capabilities = CodexRuntimeCapabilityInspector.capabilities(
            in: Data(CodexFixtures.realtimeSchema.utf8)
        )
        XCTAssertTrue(capabilities.realtimeTextV3)

        let incomplete = CodexFixtures.realtimeSchema.replacingOccurrences(
            of: "thread/realtime/appendText",
            with: "thread/realtime/missing"
        )
        XCTAssertFalse(
            CodexRuntimeCapabilityInspector.capabilities(
                in: Data(incomplete.utf8)
            ).realtimeTextV3
        )
    }

    func testBoundedProcessRunnerDrainsBothPipesWithoutDeadlock() async throws {
        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "i=0; while [ $i -lt 8192 ]; do printf x; printf y >&2; i=$((i + 1)); done",
            ],
            environment: nil,
            limits: .init(
                timeout: .seconds(2),
                standardOutputBytes: 16 * 1_024,
                standardErrorBytes: 16 * 1_024
            )
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput.count, 8_192)
        XCTAssertEqual(result.standardError.count, 8_192)
    }

    func testBoundedProcessRunnerKillsOutputFlood() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "while :; do printf output; printf error >&2; done"],
                environment: nil,
                limits: .init(
                    timeout: .seconds(2),
                    standardOutputBytes: 1_024,
                    standardErrorBytes: 1_024
                )
            )
            XCTFail("Expected the output cap to fail closed.")
        } catch let error as BoundedProcessError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testBoundedProcessRunnerCancellationKillsAndReapsChild() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-probe-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidURL = root.appendingPathComponent("pid")
        var environment = ProcessInfo.processInfo.environment
        environment["PACENOTE_PID_FILE"] = pidURL.path

        let task = Task {
            try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf '%s' \"$$\" > \"$PACENOTE_PID_FILE\"; trap '' TERM; while :; do :; done",
                ],
                environment: environment,
                limits: .init(
                    timeout: .seconds(10),
                    standardOutputBytes: 1_024,
                    standardErrorBytes: 1_024
                )
            )
        }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
        let pid = try XCTUnwrap(pid_t(pidText))
        errno = 0
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testVersionAndCapabilityProbesFailClosedOnTimeout() async throws {
        let executable = try makeProbeExecutable(
            script: "trap '' TERM; while :; do :; done"
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let started = ContinuousClock.now
        do {
            _ = try await CodexBinaryInspector.inspect(executableURL: executable)
            XCTFail("Expected a bounded version-probe failure.")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .binaryUnavailable)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))

        let capabilities = await CodexRuntimeCapabilityInspector.probe(
            executableURL: executable
        )
        XCTAssertEqual(capabilities, .none)
        XCTAssertLessThan(started.duration(to: .now), .seconds(9))
    }

    func testCodexBinaryAndLoginURLTrustPoliciesRejectSubstitutes() async throws {
        XCTAssertThrowsError(
            try CodexBinaryAuthenticityValidator.validate(
                URL(fileURLWithPath: "/bin/echo")
            )
        ) { error in
            XCTAssertEqual(error as? CodexClientError, .binaryUnavailable)
        }

        XCTAssertTrue(
            CodexChatGPTLoginURLPolicy.permits(
                try XCTUnwrap(URL(string: "https://auth.openai.com/oauth/authorize"))
            )
        )
        XCTAssertTrue(
            CodexChatGPTLoginURLPolicy.permits(
                try XCTUnwrap(URL(string: "https://chatgpt.com/auth/login"))
            )
        )
        XCTAssertFalse(
            CodexChatGPTLoginURLPolicy.permits(
                try XCTUnwrap(URL(string: "https://auth.openai.com.attacker.invalid/login"))
            )
        )
        XCTAssertFalse(
            CodexChatGPTLoginURLPolicy.permits(
                try XCTUnwrap(URL(string: "https://user@auth.openai.com/login"))
            )
        )
        XCTAssertFalse(
            CodexChatGPTLoginURLPolicy.permits(
                try XCTUnwrap(URL(string: "http://auth.openai.com/login"))
            )
        )

        let installedCodex = URL(
            fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"
        )
        if FileManager.default.isExecutableFile(atPath: installedCodex.path) {
            XCTAssertNoThrow(try CodexBinaryAuthenticityValidator.validate(installedCodex))
            let version = try await CodexBinaryInspector.inspect(executableURL: installedCodex)
            XCTAssertNoThrow(try CodexVersionPolicy.tested.validate(version))
            let capabilities = await CodexRuntimeCapabilityInspector.probe(
                executableURL: installedCodex
            )
            XCTAssertTrue(capabilities.realtimeTextV3)
        }
    }

    func testChatGPTLoginRejectsUntrustedAuthHostFromProtocolPeer() async throws {
        let transport = FixtureTransport(exchanges: [
            initializeExchange,
            .init(
                method: "account/login/start",
                params: [
                    "type": "chatgpt",
                    "useHostedLoginSuccessPage": true,
                    "appBrand": "chatgpt",
                ],
                result: CodexFixtures.value(
                    #"{"type":"chatgpt","loginId":"login-1","authUrl":"https://auth.openai.com.attacker.invalid/login"}"#
                )
            ),
        ])
        let client = makeClient(transport: transport)
        try await client.initialize()

        do {
            _ = try await client.startChatGPTLogin()
            XCTFail("Expected the untrusted login host to fail closed.")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .invalidResponse(method: "account/login/start"))
        }
        await client.shutdown()
    }

    func testInitializeAndReadOnlyDiscoveryCallsMatchFixtures() async throws {
        let transport = FixtureTransport(exchanges: [
            .init(
                method: "initialize",
                params: CodexFixtures.value(CodexFixtures.initializeParams),
                result: CodexFixtures.value(CodexFixtures.initializeResult)
            ),
            .init(
                method: "account/read",
                params: ["refreshToken": false],
                result: CodexFixtures.value(CodexFixtures.accountResult)
            ),
            .init(
                method: "model/list",
                params: ["limit": 100, "includeHidden": false],
                result: CodexFixtures.value(CodexFixtures.modelPage)
            ),
            .init(
                method: "account/rateLimits/read",
                params: nil,
                result: CodexFixtures.value(CodexFixtures.rateLimitsResult)
            ),
            .init(
                method: "permissionProfile/list",
                params: ["cwd": "/tmp/pacenote-snapshot", "limit": 100],
                result: CodexFixtures.value(CodexFixtures.permissionProfilesResult)
            ),
            .init(
                method: "skills/list",
                params: [
                    "cwds": ["/tmp/pacenote-snapshot"],
                    "forceReload": false,
                ],
                result: CodexFixtures.value(CodexFixtures.skillsResult)
            ),
        ])
        let client = makeClient(transport: transport)
        try await client.initialize()

        let account = try await client.account()
        let models = try await client.listModels()
        let limits = try await client.rateLimits()
        let profiles = try await client.listPermissionProfiles(cwd: "/tmp/pacenote-snapshot")
        let skills = try await client.listSkills(cwds: ["/tmp/pacenote-snapshot"])

        XCTAssertEqual(account.account?.type, "chatgpt")
        XCTAssertEqual(account.account?.planType, "pro")
        XCTAssertEqual(models.map(\.id), ["quick-model"])
        XCTAssertEqual(limits.rateLimits.limitId, "codex")
        XCTAssertEqual(profiles.map(\.id), [":read-only"])
        XCTAssertEqual(skills.data.first?.skills.first?.name, "repo-answer")
        let sentNotifications = await transport.sentNotifications()
        let exhausted = await transport.isExhausted()
        XCTAssertEqual(sentNotifications, [.init(method: "initialized", params: nil)])
        XCTAssertTrue(exhausted)
        await client.shutdown()
    }

    func testInitializeRejectsMismatchedCodexHomeBeforeInitialized() async throws {
        let mismatchedResult = CodexFixtures.initializeResult.replacingOccurrences(
            of: #"/Users/redacted/.codex"#,
            with: #"/Users/redacted/another-codex-home"#
        )
        let transport = FixtureTransport(exchanges: [
            .init(
                method: "initialize",
                params: CodexFixtures.value(CodexFixtures.initializeParams),
                result: CodexFixtures.value(mismatchedResult)
            )
        ])
        let client = makeClient(transport: transport)

        do {
            try await client.initialize()
            XCTFail("Expected a mismatched Codex home to fail closed.")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .profileMismatch)
        }

        let notifications = await transport.sentNotifications()
        let stopped = await transport.wasStopped()
        let exhausted = await transport.isExhausted()
        XCTAssertTrue(notifications.isEmpty)
        XCTAssertTrue(stopped)
        XCTAssertTrue(exhausted)
    }

    func testPersistentBaseMaterializesBeforePermissionRepeatedEphemeralFork() async throws {
        let startParams: JSONValue = [
            "model": "deep-model",
            "cwd": "/tmp/pacenote-snapshot",
            "runtimeWorkspaceRoots": ["/tmp/pacenote-snapshot"],
            "approvalPolicy": "never",
            "permissions": ":read-only",
            "ephemeral": false,
            "serviceName": "pacenote",
        ]
        let injectParams: JSONValue = [
            "threadId": "base-thread",
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
        let forkParams: JSONValue = [
            "threadId": "base-thread",
            "ephemeral": true,
            "excludeTurns": true,
            "approvalPolicy": "never",
            "permissions": ":read-only",
            "runtimeWorkspaceRoots": ["/tmp/pacenote-snapshot"],
            "model": "quick-model",
        ]
        let transport = FixtureTransport(exchanges: [
            initializeExchange,
            .init(
                method: "thread/start",
                params: startParams,
                result: CodexFixtures.value(CodexFixtures.baseThreadResult)
            ),
            .init(
                method: "thread/inject_items",
                params: injectParams,
                result: CodexFixtures.value(CodexFixtures.emptyResult)
            ),
            .init(
                method: "thread/fork",
                params: forkParams,
                result: CodexFixtures.value(CodexFixtures.forkThreadResult)
            ),
            .init(
                method: "thread/delete",
                params: ["threadId": "base-thread"],
                result: CodexFixtures.value(CodexFixtures.emptyResult)
            ),
        ])
        let client = makeClient(transport: transport)
        try await client.initialize()

        let base = try await client.createPersistentBase(
            cwd: "/tmp/pacenote-snapshot",
            runtimeWorkspaceRoots: ["/tmp/pacenote-snapshot"],
            model: "deep-model"
        )
        let fork = try await client.forkEphemeral(from: base, model: "quick-model")
        try await client.deleteThread(id: base.id)

        XCTAssertEqual(base.id, "base-thread")
        XCTAssertEqual(fork.id, "fork-thread")
        XCTAssertEqual(fork.permissionProfileID, ":read-only")
        let exhausted = await transport.isExhausted()
        XCTAssertTrue(exhausted)
        await client.shutdown()
    }

    func testBaseCreationPublishesOpaqueIDBeforeMetadataValidation() async throws {
        let startParams: JSONValue = [
            "model": "deep-model",
            "cwd": "/tmp/pacenote-snapshot",
            "runtimeWorkspaceRoots": ["/tmp/pacenote-snapshot"],
            "approvalPolicy": "never",
            "permissions": ":read-only",
            "ephemeral": false,
            "serviceName": "pacenote",
        ]
        var malformed = try XCTUnwrap(
            CodexFixtures.value(CodexFixtures.baseThreadResult).objectValue
        )
        malformed["cwd"] = "/tmp/unexpected-cwd"
        let transport = FixtureTransport(exchanges: [
            initializeExchange,
            .init(method: "thread/start", params: startParams, result: .object(malformed)),
            .init(
                method: "thread/delete",
                params: ["threadId": "base-thread"],
                result: CodexFixtures.value(CodexFixtures.emptyResult)
            ),
        ])
        let recorder = CreatedThreadIDRecorder()
        let client = makeClient(transport: transport)
        try await client.initialize()

        do {
            _ = try await client.createPersistentBase(
                cwd: "/tmp/pacenote-snapshot",
                runtimeWorkspaceRoots: ["/tmp/pacenote-snapshot"],
                model: "deep-model",
                baseInstructions: nil,
                onCreated: { await recorder.record($0) }
            )
            XCTFail("Expected malformed base metadata")
        } catch let failure as CodexCreatedThreadFailure {
            XCTAssertEqual(failure.threadID, "base-thread")
            XCTAssertEqual(failure.cause, .client(.permissionProfileMismatch))
            let identifiers = await recorder.identifiers()
            XCTAssertEqual(identifiers, ["base-thread"])
            try await client.deleteThread(id: failure.threadID)
        }

        let baseExchangesExhausted = await transport.isExhausted()
        XCTAssertTrue(baseExchangesExhausted)
        await client.shutdown()
    }

    func testForkCreationPublishesOpaqueIDBeforeMetadataValidation() async throws {
        let base = CodexBaseThread(
            id: "base-thread",
            model: "deep-model",
            permissionProfileID: ":read-only",
            cwd: "/tmp/pacenote-snapshot",
            runtimeWorkspaceRoots: ["/tmp/pacenote-snapshot"],
            instructionSources: ["/tmp/pacenote-snapshot/AGENTS.md"]
        )
        let forkParams: JSONValue = [
            "threadId": "base-thread",
            "ephemeral": true,
            "excludeTurns": true,
            "approvalPolicy": "never",
            "permissions": ":read-only",
            "runtimeWorkspaceRoots": ["/tmp/pacenote-snapshot"],
            "model": "quick-model",
        ]
        var malformed = try XCTUnwrap(
            CodexFixtures.value(CodexFixtures.forkThreadResult).objectValue
        )
        malformed["runtimeWorkspaceRoots"] = ["/tmp/unexpected-root"]
        let transport = FixtureTransport(exchanges: [
            initializeExchange,
            .init(method: "thread/fork", params: forkParams, result: .object(malformed)),
            .init(
                method: "thread/delete",
                params: ["threadId": "fork-thread"],
                result: CodexFixtures.value(CodexFixtures.emptyResult)
            ),
        ])
        let recorder = CreatedThreadIDRecorder()
        let client = makeClient(transport: transport)
        try await client.initialize()

        do {
            _ = try await client.forkEphemeral(
                from: base,
                model: "quick-model",
                onCreated: { await recorder.record($0) }
            )
            XCTFail("Expected malformed fork metadata")
        } catch let failure as CodexCreatedThreadFailure {
            XCTAssertEqual(failure.threadID, "fork-thread")
            XCTAssertEqual(failure.cause, .client(.permissionProfileMismatch))
            let identifiers = await recorder.identifiers()
            XCTAssertEqual(identifiers, ["fork-thread"])
            try await client.deleteThread(id: failure.threadID)
        }

        let forkExchangesExhausted = await transport.isExhausted()
        XCTAssertTrue(forkExchangesExhausted)
        await client.shutdown()
    }

    func testThreadListingPagesAppServerThreadsForExactCleanupCwd() async throws {
        let firstParams: JSONValue = [
            "limit": 100,
            "cwd": "/tmp/pacenote-meeting",
            "sourceKinds": ["appServer"],
            "archived": false,
        ]
        var secondParams = try XCTUnwrap(firstParams.objectValue)
        secondParams["cursor"] = "next"
        let transport = FixtureTransport(exchanges: [
            initializeExchange,
            .init(
                method: "thread/list",
                params: firstParams,
                result: [
                    "data": [["id": "base-1"]],
                    "nextCursor": "next",
                ]
            ),
            .init(
                method: "thread/list",
                params: .object(secondParams),
                result: [
                    "data": [["id": "fork-1"]],
                    "nextCursor": .null,
                ]
            ),
        ])
        let client = makeClient(transport: transport)
        try await client.initialize()

        let identifiers = try await client.listThreadIDs(cwd: "/tmp/pacenote-meeting")
        let exhausted = await transport.isExhausted()

        XCTAssertEqual(identifiers, ["base-1", "fork-1"])
        XCTAssertTrue(exhausted)
        await client.shutdown()
    }

    func testTurnCollectsNotificationsAroundResponseAndInterruptsExactly() async throws {
        let outputSchema: JSONValue = [
            "type": "object",
            "properties": ["sayNow": ["type": "string"]],
            "required": ["sayNow"],
            "additionalProperties": false,
        ]
        let turnParams: JSONValue = [
            "threadId": "fork-thread",
            "input": [
                [
                    "type": "text",
                    "text": "What should I say?",
                    "text_elements": [],
                ]
            ],
            "approvalPolicy": "never",
            "permissions": ":read-only",
            "model": "quick-model",
            "effort": "low",
            "outputSchema": outputSchema,
        ]
        let transport = FixtureTransport(exchanges: [
            initializeExchange,
            .init(
                method: "turn/start",
                params: turnParams,
                result: CodexFixtures.value(CodexFixtures.turnStartResult),
                eventsBeforeResult: [
                    .notification(CodexFixtures.inbound(CodexFixtures.agentDeltaNotification)),
                    .notification(CodexFixtures.inbound(CodexFixtures.itemCompletedNotification)),
                    .notification(CodexFixtures.inbound(CodexFixtures.turnCompletedNotification)),
                ]
            ),
            .init(
                method: "turn/interrupt",
                params: ["threadId": "fork-thread", "turnId": "turn-1"],
                result: CodexFixtures.value(CodexFixtures.emptyResult)
            ),
        ])
        let client = makeClient(transport: transport)
        try await client.initialize()

        let quickSession = try await client.startQuick(
            threadID: "fork-thread",
            text: "What should I say?",
            realtimePrompt: "Return one short speakable answer.",
            model: "quick-model",
            outputSchema: outputSchema
        )
        guard case .turn(let session) = quickSession else {
            return XCTFail("Unsupported realtime must use the ordinary turn fallback.")
        }
        try await client.interruptTurn(threadID: session.threadID, turnID: session.turnID)

        var events: [CodexTurnEvent] = []
        for try await event in session.events { events.append(event) }
        XCTAssertEqual(events.first, .agentMessageDelta(itemID: "item-1", delta: "A short answer"))
        XCTAssertEqual(events.last, .completed(status: "completed"))
        XCTAssertEqual(events.count, 3)
        let exhausted = await transport.isExhausted()
        XCTAssertTrue(exhausted)
        await client.shutdown()
    }

    func testRealtimeQuickUsesTextOnlyV3AndCollectsTypedEvents() async throws {
        let startParams: JSONValue = [
            "threadId": "fork-thread",
            "clientManagedHandoffs": true,
            "outputModality": "text",
            "prompt": "Return one short speakable answer.",
            "version": "v3",
            "model": "quick-model",
        ]
        let transport = FixtureTransport(exchanges: [
            initializeExchange,
            .init(
                method: "thread/realtime/start",
                params: startParams,
                result: CodexFixtures.value(CodexFixtures.emptyResult),
                eventsBeforeResult: [
                    .notification(CodexFixtures.inbound(CodexFixtures.realtimeStartedNotification))
                ]
            ),
            .init(
                method: "thread/realtime/appendText",
                params: [
                    "threadId": "fork-thread",
                    "text": "What should I say?",
                    "role": "user",
                ],
                result: CodexFixtures.value(CodexFixtures.emptyResult),
                eventsBeforeResult: [
                    .notification(CodexFixtures.inbound(CodexFixtures.realtimeDeltaNotification)),
                    .notification(CodexFixtures.inbound(CodexFixtures.realtimeDoneNotification)),
                    .notification(CodexFixtures.inbound(CodexFixtures.realtimeItemNotification)),
                ]
            ),
            .init(
                method: "thread/realtime/stop",
                params: ["threadId": "fork-thread"],
                result: CodexFixtures.value(CodexFixtures.emptyResult),
                eventsBeforeResult: [
                    .notification(CodexFixtures.inbound(CodexFixtures.realtimeClosedNotification))
                ]
            ),
        ])
        let client = makeClient(
            transport: transport,
            runtimeCapabilities: .init(realtimeTextV3: true)
        )
        try await client.initialize()

        let quickSession = try await client.startQuick(
            threadID: "fork-thread",
            text: "What should I say?",
            realtimePrompt: "Return one short speakable answer.",
            model: "quick-model"
        )
        guard case .realtime(let session) = quickSession else {
            return XCTFail("The proven V3 surface should use realtime text.")
        }
        try await client.stopRealtimeText(threadID: session.threadID)

        var events: [CodexRealtimeEvent] = []
        for try await event in session.events { events.append(event) }
        XCTAssertEqual(events.first, .started(sessionID: "rt-1", version: "v3"))
        XCTAssertTrue(events.contains(.transcriptDelta(role: "assistant", delta: "Say this")))
        XCTAssertTrue(events.contains(.transcriptDone(role: "assistant", text: "Say this now.")))
        XCTAssertEqual(events.last, .closed)
        let exhausted = await transport.isExhausted()
        XCTAssertTrue(exhausted)
        await client.shutdown()
    }

    func testUnexpectedServerRequestFailsActiveTurnClosed() async throws {
        let transport = FixtureTransport(exchanges: [
            initializeExchange,
            .init(
                method: "turn/start",
                params: [
                    "threadId": "fork-thread",
                    "input": [
                        [
                            "type": "text",
                            "text": "Answer briefly.",
                            "text_elements": [],
                        ]
                    ],
                    "approvalPolicy": "never",
                    "permissions": ":read-only",
                ],
                result: CodexFixtures.value(CodexFixtures.turnStartResult)
            ),
        ])
        let client = makeClient(transport: transport)
        try await client.initialize()
        let session = try await client.startTurn(
            threadID: "fork-thread",
            text: "Answer briefly."
        )

        await transport.emit(
            .rejectedServerRequest(
                method: "item/commandExecution/requestApproval",
                threadID: "fork-thread",
                turnID: "turn-1",
                itemID: "command-item"
            )
        )

        do {
            for try await _ in session.events {}
            XCTFail("Expected the active turn to fail closed.")
        } catch let error as CodexClientError {
            XCTAssertEqual(
                error,
                .serverRequestRejected(
                    method: "item/commandExecution/requestApproval",
                    threadID: "fork-thread",
                    turnID: "turn-1",
                    itemID: "command-item"
                )
            )
            XCTAssertFalse(error.localizedDescription.contains("/Users/"))
            XCTAssertFalse(error.localizedDescription.contains("fork-thread"))
            XCTAssertFalse(error.localizedDescription.contains("turn-1"))
            XCTAssertFalse(error.localizedDescription.contains("command-item"))
        }
        let stopped = await transport.wasStopped()
        XCTAssertTrue(stopped)
    }

    func testLiveReadOnlyLifecycleWithoutModelGeneration() async throws {
        guard ProcessInfo.processInfo.environment["PACENOTE_RUN_CODEX_READONLY_SMOKE"] == "1" else {
            throw XCTSkip("Set PACENOTE_RUN_CODEX_READONLY_SMOKE=1 for the local zero-generation smoke.")
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-live-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let isolated = try CodexIsolatedRuntimeBuilder.prepare(
            profileRoot: temporaryDirectory.appendingPathComponent("profile", isDirectory: true),
            temporaryRoot: temporaryDirectory.appendingPathComponent("codex-tmp", isDirectory: true)
        )

        let client = try await CodexAppServerClient.connect(
            configuration: .init(
                expectedCodexHome: isolated.profileRoot,
                clientVersion: "0.1.0",
                permissionProfileID: isolated.permissionProfileID,
                processArguments: isolated.processArguments,
                processEnvironment: isolated.processEnvironment
            )
        )
        do {
            let account = try await client.account()
            let models = try await client.listModels()
            let profiles = try await client.listPermissionProfiles(
                cwd: temporaryDirectory.path
            )
            _ = try await client.rateLimits()
            _ = try await client.listSkills(cwds: [temporaryDirectory.path])

            XCTAssertEqual(account.account?.type, "chatgpt")
            XCTAssertFalse(models.isEmpty)
            XCTAssertTrue(profiles.contains { $0.id == ":read-only" && $0.allowed })
            XCTAssertTrue(client.runtimeCapabilities.realtimeTextV3)

            let base = try await client.createPersistentBase(
                cwd: temporaryDirectory.path,
                runtimeWorkspaceRoots: [temporaryDirectory.path],
                model: try XCTUnwrap(models.first?.id)
            )
            do {
                let fork = try await client.forkEphemeral(from: base)
                XCTAssertTrue(fork.id != base.id)
                try await client.deleteThread(id: base.id)
            } catch {
                try? await client.deleteThread(id: base.id)
                throw error
            }
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private var initializeExchange: FixtureExchange {
        .init(
            method: "initialize",
            params: CodexFixtures.value(CodexFixtures.initializeParams),
            result: CodexFixtures.value(CodexFixtures.initializeResult)
        )
    }

    private func makeProbeExecutable(script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let executable = root.appendingPathComponent("probe")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private func makeClient(
        transport: FixtureTransport,
        runtimeCapabilities: CodexRuntimeCapabilities = .none
    ) -> CodexAppServerClient {
        CodexAppServerClient(
            transport: transport,
            configuration: .init(
                expectedCodexHome: URL(
                    fileURLWithPath: "/Users/redacted/.codex",
                    isDirectory: true
                ),
                clientVersion: "0.1.0"
            ),
            binaryVersion: .init(
                major: 0,
                minor: 147,
                patch: 0,
                prerelease: "alpha.1.2"
            ),
            runtimeCapabilities: runtimeCapabilities
        )
    }
}

private struct FixtureExchange: Sendable {
    let method: String
    let params: JSONValue?
    let result: JSONValue
    let eventsBeforeResult: [CodexTransportEvent]

    init(
        method: String,
        params: JSONValue?,
        result: JSONValue,
        eventsBeforeResult: [CodexTransportEvent] = []
    ) {
        self.method = method
        self.params = params
        self.result = result
        self.eventsBeforeResult = eventsBeforeResult
    }
}

private actor CreatedThreadIDRecorder {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func identifiers() -> [String] { values }
}

private actor FixtureTransport: CodexRPCTransporting {
    private var exchanges: [FixtureExchange]
    private var notifications: [CodexServerNotification] = []
    private var continuations: [UUID: AsyncStream<CodexTransportEvent>.Continuation] = [:]
    private var stopped = false

    init(exchanges: [FixtureExchange]) {
        self.exchanges = exchanges
    }

    func start() async throws {}

    func stop() async {
        stopped = true
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    func request(method: String, params: JSONValue?) async throws -> JSONValue {
        guard !exchanges.isEmpty else {
            throw CodexClientError.invalidResponse(method: method)
        }
        let exchange = exchanges.removeFirst()
        guard exchange.method == method, exchange.params == params else {
            throw CodexClientError.invalidResponse(method: method)
        }
        for event in exchange.eventsBeforeResult { emit(event) }
        return exchange.result
    }

    func sendNotification(method: String, params: JSONValue?) async throws {
        notifications.append(.init(method: method, params: params))
    }

    func events() async -> AsyncStream<CodexTransportEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
        }
    }

    func emit(_ event: CodexTransportEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    func sentNotifications() -> [CodexServerNotification] { notifications }
    func isExhausted() -> Bool { exchanges.isEmpty }
    func wasStopped() -> Bool { stopped }
}
