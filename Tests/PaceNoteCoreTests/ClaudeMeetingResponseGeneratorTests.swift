import Foundation
import XCTest

@testable import PaceNoteCore

final class ClaudeMeetingResponseGeneratorTests: XCTestCase {
    func testPrepareUsesSubscriptionAndExposesDeterministicQuickAndSonnetDeepRoutes() async throws {
        let fixture = try ClaudeGeneratorFixture()
        defer { fixture.cleanup() }
        let checker = FixedClaudeSubscriptionChecker(
            status: ClaudeSubscriptionStatus(
                planType: "max",
                redactedLabel: "p…@example.invalid",
                identityHash: String(repeating: "a", count: 64)
            )
        )
        let runner = CapturingClaudeRunner(results: [])
        let generator = fixture.generator(runner: runner, subscriptionChecker: checker)

        let runtime = try await generator.prepare()
        let quick = try await generator.generateQuick(for: fixture.generalTurn())

        XCTAssertEqual(runtime.planType, "max")
        XCTAssertEqual(runtime.quickRoute, CodexModelRoute(model: "local-deterministic-bridge", effort: "none"))
        XCTAssertEqual(runtime.deepRoute, CodexModelRoute(model: "sonnet", effort: "high"))
        XCTAssertFalse(runtime.usesRealtimeQuick)
        XCTAssertEqual(
            quick.sayNow,
            "I'd start by clarifying the goal and constraints, then walk through the tradeoffs before committing to an approach."
        )
        XCTAssertTrue(quick.needsDeep)
        let requests = await runner.requests()
        let report = await generator.shutdown()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(report.failures, [])
    }

    func testDeepSendsMeetingAndEvidenceDataOnlyThroughBoundedStandardInput() async throws {
        let fixture = try ClaudeGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.generalTurn(
            question: "How should we choose the queue boundary?",
            transcript: "The current retry behavior is unclear.",
            speakerBrief: "Eight years with React; lately building TypeScript AI products."
        )
        let draft = DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext: "I would identify the main failure modes before choosing a design.",
            confidence: 0.72,
            basis: []
        )
        let runner = CapturingClaudeRunner(results: [try Self.successEnvelope(draft)])
        let generator = fixture.generator(runner: runner)
        _ = try await generator.prepare()

        let output = try await generator.generateDeep(for: turn)
        let requests = await runner.requests()
        let request = try XCTUnwrap(requests.only)
        let argvAndEnvironment =
            request.arguments.joined(separator: " ")
            + request.environment.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            + request.currentDirectoryURL.path

        XCTAssertEqual(output, draft)
        XCTAssertEqual(request.arguments, fixture.runtime.processArguments)
        XCTAssertEqual(request.environment, fixture.runtime.processEnvironment)
        XCTAssertLessThanOrEqual(request.standardInput.count, 32 * 1_024)
        XCTAssertFalse(argvAndEnvironment.contains(turn.question))
        XCTAssertFalse(argvAndEnvironment.contains(turn.recentTranscript[0].text))
        let input = try JSONDecoder().decode(JSONValue.self, from: request.standardInput)
        XCTAssertEqual(input["meetingQuestion"]?.stringValue, turn.question)
        XCTAssertEqual(input["expected"]?["turnID"]?.stringValue, turn.identity.turnID.uuidString)
        XCTAssertEqual(input["speakerBrief"]?.stringValue, turn.speakerBrief)
        XCTAssertNil(input["sealedEvidence"]?.objectValue)
        let report = await generator.shutdown()
        XCTAssertEqual(report.failures, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configuration.runtimeRoot.path))
    }

    func testGroundedAnswerRejectsCitationOutsideProvidedPackBeforeEvidenceVerification() async throws {
        let fixture = try ClaudeGeneratorFixture(includeGrounding: true)
        defer { fixture.cleanup() }
        let turn = fixture.groundedTurn()
        let invalidReference = EvidenceReference(
            repoAlias: "service",
            relativePath: "Sources/Other.swift",
            startLine: 7,
            endLine: 7,
            fileHash: String(repeating: "b", count: 64),
            claim: "Retries are bounded to three attempts."
        )
        let draft = DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: turn.groundingFingerprint,
            kind: .answer,
            candidateSayNext: invalidReference.claim,
            confidence: 0.9,
            basis: [invalidReference]
        )
        let runner = CapturingClaudeRunner(results: [try Self.successEnvelope(draft)])
        let verifier = RecordingClaudeEvidenceVerifier()
        let generator = fixture.generator(
            runner: runner,
            evidenceVerifier: verifier,
            groundingPackBuilder: FixedClaudeGroundingPackBuilder(pack: fixture.pack)
        )
        _ = try await generator.prepare()

        await XCTAssertThrowsClaudeMeetingError(.groundingMismatch) {
            _ = try await generator.generateDeep(for: turn)
        }
        let verificationCount = await verifier.verificationCount()
        XCTAssertEqual(verificationCount, 0)
        _ = await generator.shutdown()
    }

    func testPrepareRejectsBoundClaudeAccountMismatchWithoutLaunchingGeneration() async throws {
        let fixture = try ClaudeGeneratorFixture(expectedIdentityHash: String(repeating: "0", count: 64))
        defer { fixture.cleanup() }
        let runner = CapturingClaudeRunner(results: [])
        let generator = fixture.generator(runner: runner)

        await XCTAssertThrowsClaudeMeetingError(.accountMismatch) {
            _ = try await generator.prepare()
        }
        let requests = await runner.requests()
        XCTAssertTrue(requests.isEmpty)
        _ = await generator.shutdown()
    }

    func testDeepRechecksClaudeAccountAndRejectsAChangedIdentityBeforeLaunch() async throws {
        let fixture = try ClaudeGeneratorFixture()
        defer { fixture.cleanup() }
        let prepared = ClaudeSubscriptionStatus(
            planType: "max",
            redactedLabel: "p…@example.invalid",
            identityHash: String(repeating: "a", count: 64)
        )
        let changed = ClaudeSubscriptionStatus(
            planType: "max",
            redactedLabel: "c…@example.invalid",
            identityHash: String(repeating: "b", count: 64)
        )
        let checker = SequencedClaudeSubscriptionChecker(statuses: [prepared, changed])
        let runner = CapturingClaudeRunner(results: [])
        let generator = fixture.generator(runner: runner, subscriptionChecker: checker)
        _ = try await generator.prepare()

        await XCTAssertThrowsClaudeMeetingError(.accountMismatch) {
            _ = try await generator.generateDeep(for: fixture.generalTurn())
        }
        let requests = await runner.requests()
        XCTAssertTrue(requests.isEmpty)
        _ = await generator.shutdown()
    }

    func testConcurrentSecondDeepIsRejectedWhileFirstRunnerIsSuspended() async throws {
        let fixture = try ClaudeGeneratorFixture()
        defer { fixture.cleanup() }
        let runner = ControllableClaudeRunner(resultsAfterSuspension: [])
        let generator = fixture.generator(runner: runner)
        let turn = fixture.generalTurn()
        _ = try await generator.prepare()

        let firstDeep = Task { try await generator.generateDeep(for: turn) }
        await runner.waitUntilFirstRunIsSuspended()

        await XCTAssertThrowsClaudeMeetingError(.deepAlreadyActive) {
            _ = try await generator.generateDeep(for: turn)
        }

        await generator.cancelActiveWork()
        await XCTAssertClaudeTaskCancelled(firstDeep)
        let requestCount = await runner.requestCount()
        XCTAssertEqual(requestCount, 1)
        _ = await generator.shutdown()
    }

    func testCancelActiveWorkWaitsForRunnerThenKeepsPreparedGeneratorUsable() async throws {
        let fixture = try ClaudeGeneratorFixture()
        defer { fixture.cleanup() }
        let turn = fixture.generalTurn()
        let recoveredDraft = DeepDraft(
            turnID: turn.identity.turnID,
            generation: turn.identity.generation,
            groundingFingerprint: nil,
            kind: .generalAnswer,
            candidateSayNext: "I would identify the main failure modes before choosing a design.",
            confidence: 0.72,
            basis: []
        )
        let runner = ControllableClaudeRunner(
            resultsAfterSuspension: [try Self.successEnvelope(recoveredDraft)],
            holdCancellationUntilReleased: true
        )
        let generator = fixture.generator(runner: runner)
        let prepared = try await generator.prepare()

        let firstDeep = Task { try await generator.generateDeep(for: turn) }
        await runner.waitUntilFirstRunIsSuspended()
        let completion = ClaudeLifecycleCompletionProbe()
        let cancellation = Task {
            await generator.cancelActiveWork()
            await completion.markCompleted()
        }
        await runner.waitUntilCancellationIsRequested()
        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(completedBeforeRelease)

        await runner.releaseCancellation()
        await cancellation.value
        await XCTAssertClaudeTaskCancelled(firstDeep)
        let completedAfterRelease = await completion.isCompleted()
        let runtimeAfterCancellation = try await generator.prepare()
        XCTAssertTrue(completedAfterRelease)
        XCTAssertEqual(runtimeAfterCancellation, prepared)

        let recovered = try await generator.generateDeep(for: turn)
        XCTAssertEqual(recovered, recoveredDraft)
        let requestCount = await runner.requestCount()
        XCTAssertEqual(requestCount, 2)
        _ = await generator.shutdown()
    }

    func testConcurrentShutdownDuringDeepWaitsRemovesExactRuntimeRootAndIsIdempotent() async throws {
        let fixture = try ClaudeGeneratorFixture()
        defer { fixture.cleanup() }
        let sentinel = fixture.meetingRoot.appendingPathComponent("keep-me", isDirectory: false)
        try Data("meeting-private-state".utf8).write(to: sentinel, options: .atomic)
        let runner = ControllableClaudeRunner(
            resultsAfterSuspension: [],
            holdCancellationUntilReleased: true
        )
        let generator = fixture.generator(runner: runner)
        let turn = fixture.generalTurn()
        _ = try await generator.prepare()

        let deep = Task { try await generator.generateDeep(for: turn) }
        await runner.waitUntilFirstRunIsSuspended()
        let firstShutdown = Task { await generator.shutdown() }
        await runner.waitUntilCancellationIsRequested()
        let secondShutdown = Task { await generator.shutdown() }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.configuration.runtimeRoot.path),
            "Shutdown must wait for the active runner before deleting its runtime."
        )
        await runner.releaseCancellation()

        let firstReport = await firstShutdown.value
        let secondReport = await secondShutdown.value
        let repeatedReport = await generator.shutdown()
        await XCTAssertClaudeTaskCancelled(deep)

        XCTAssertEqual(firstReport, MeetingResponseCleanupReport())
        XCTAssertEqual(secondReport, firstReport)
        XCTAssertEqual(repeatedReport, firstReport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configuration.runtimeRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.meetingRoot.path))
    }

    private static func successEnvelope(_ draft: DeepDraft) throws -> ClaudeCommandResult {
        let envelope: JSONValue = [
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "num_turns": 1,
            "permission_denials": [],
            "structured_output": try JSONValue.encode(draft),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ClaudeCommandResult(
            standardOutput: try encoder.encode(envelope),
            standardError: Data(),
            terminationStatus: 0
        )
    }
}

private final class ClaudeGeneratorFixture {
    let meetingRoot: URL
    let configuration: ClaudeMeetingResponseConfiguration
    let runtime: ClaudeIsolatedRuntime
    let snapshot: GroundingSnapshot?
    let pack: ClaudeGroundingPack

    init(includeGrounding: Bool = false, expectedIdentityHash: String? = nil) throws {
        let fileManager = FileManager.default
        meetingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("PaceNote-Claude-Generator-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: meetingRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let runtimeRoot = meetingRoot.appendingPathComponent("claude-runtime", isDirectory: true)
        let work = runtimeRoot.appendingPathComponent("work", isDirectory: true)
        let temporary = runtimeRoot.appendingPathComponent("tmp", isDirectory: true)
        try fileManager.createDirectory(
            at: work,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let executable = runtimeRoot.appendingPathComponent("claude-test", isDirectory: false)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let trust = try ClaudeExecutableTrustSnapshot.capture(
            executable,
            authenticityValidation: { _ in }
        )
        runtime = ClaudeIsolatedRuntime(
            executableURL: executable,
            executableTrustSnapshot: trust,
            workingDirectory: work,
            temporaryDirectory: temporary,
            processArguments: try ClaudeRuntimeArguments.deep(),
            processEnvironment: [
                "HOME": "/redacted-home",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "USER": "local-user",
            ]
        )

        if includeGrounding {
            let snapshotRoot = meetingRoot.appendingPathComponent("snapshot", isDirectory: true)
            try fileManager.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
            let manifest = GroundingManifest(entries: [])
            let inspection = GroundingInspection(
                branch: "main",
                head: String(repeating: "1", count: 40),
                worktreeFingerprint: String(repeating: "2", count: 64),
                manifest: manifest,
                groundingFingerprint: "grounding-fingerprint",
                hardExclusions: [],
                softFindings: [],
                acceptedApprovals: [],
                instructionSources: []
            )
            snapshot = GroundingSnapshot(
                id: UUID(),
                repoAlias: "service",
                sourceRoot: meetingRoot.appendingPathComponent("unused-source", isDirectory: true),
                snapshotRoot: snapshotRoot,
                createdAt: Date(),
                inspection: inspection
            )
        } else {
            snapshot = nil
        }
        pack = ClaudeGroundingPack(
            repoAlias: "service",
            groundingFingerprint: "grounding-fingerprint",
            excerpts: [
                ClaudeGroundingExcerpt(
                    repoAlias: "service",
                    relativePath: "Sources/Retry.swift",
                    lineNumber: 7,
                    fileHash: String(repeating: "a", count: 64),
                    exactLine: "Retries are bounded to three attempts."
                )
            ]
        )
        configuration = ClaudeMeetingResponseConfiguration(
            meetingID: UUID(),
            meetingPrivateRoot: meetingRoot,
            expectedAccountIdentityHash: expectedIdentityHash,
            groundingSnapshot: snapshot
        )
    }

    func generator(
        runner: any ClaudeCommandRunning,
        subscriptionChecker: (any ClaudeSubscriptionChecking)? = nil,
        evidenceVerifier: any MeetingEvidenceVerifying = RecordingClaudeEvidenceVerifier(),
        groundingPackBuilder: any ClaudeGroundingPackBuilding = ClaudeGroundingPackBuilder()
    ) -> ClaudeMeetingResponseGenerator {
        ClaudeMeetingResponseGenerator(
            configuration: configuration,
            runner: runner,
            subscriptionChecker: subscriptionChecker
                ?? FixedClaudeSubscriptionChecker(
                    status: ClaudeSubscriptionStatus(
                        planType: "max",
                        redactedLabel: "p…@example.invalid",
                        identityHash: String(repeating: "a", count: 64)
                    )
                ),
            evidenceVerifier: evidenceVerifier,
            groundingPackBuilder: groundingPackBuilder,
            runtimePreparer: { [runtime] _ in runtime },
            versionVerifier: { _ in },
            executableRevalidator: { _ in },
            managedPolicyValidator: {}
        )
    }

    func generalTurn(
        question: String = "What should I say?",
        transcript: String = "Can you explain the tradeoff?",
        speakerBrief: String? = nil
    ) -> ConversationTurn {
        ConversationTurn(
            identity: TurnIdentity(meetingID: configuration.meetingID, generation: 1),
            question: question,
            recentTranscript: [
                TranscriptSegment(
                    source: .them,
                    text: transcript,
                    startedAt: 1,
                    endedAt: 2,
                    isFinal: true
                )
            ],
            speakerBrief: speakerBrief
        )
    }

    func groundedTurn() -> ConversationTurn {
        ConversationTurn(
            identity: TurnIdentity(meetingID: configuration.meetingID, generation: 1),
            question: "How many retry attempts are allowed?",
            recentTranscript: [],
            repoAlias: snapshot?.repoAlias,
            groundingFingerprint: snapshot?.groundingFingerprint
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: meetingRoot)
    }
}

private actor CapturingClaudeRunner: ClaudeCommandRunning {
    private var results: [ClaudeCommandResult]
    private var captured: [ClaudeCommandRequest] = []

    init(results: [ClaudeCommandResult]) {
        self.results = results
    }

    func run(_ request: ClaudeCommandRequest) async throws -> ClaudeCommandResult {
        captured.append(request)
        guard !results.isEmpty else { throw ClaudeCommandError.launchFailed }
        return results.removeFirst()
    }

    func cancelActive() async {}

    func requests() -> [ClaudeCommandRequest] { captured }
}

private actor ControllableClaudeRunner: ClaudeCommandRunning {
    private var resultsAfterSuspension: [ClaudeCommandResult]
    private let holdCancellationUntilReleased: Bool
    private var cancellationReleased: Bool
    private var shouldSuspendNextRun = true
    private var activeRun: CheckedContinuation<ClaudeCommandResult, any Error>?
    private var captured: [ClaudeCommandRequest] = []
    private var firstRunIsSuspended = false
    private var firstRunWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationIsRequested = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        resultsAfterSuspension: [ClaudeCommandResult],
        holdCancellationUntilReleased: Bool = false
    ) {
        self.resultsAfterSuspension = resultsAfterSuspension
        self.holdCancellationUntilReleased = holdCancellationUntilReleased
        self.cancellationReleased = !holdCancellationUntilReleased
    }

    func run(_ request: ClaudeCommandRequest) async throws -> ClaudeCommandResult {
        captured.append(request)
        if shouldSuspendNextRun {
            shouldSuspendNextRun = false
            return try await withCheckedThrowingContinuation { continuation in
                activeRun = continuation
                firstRunIsSuspended = true
                let waiters = firstRunWaiters
                firstRunWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        guard !resultsAfterSuspension.isEmpty else {
            throw ClaudeCommandError.launchFailed
        }
        return resultsAfterSuspension.removeFirst()
    }

    func cancelActive() async {
        cancellationIsRequested = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        if holdCancellationUntilReleased, !cancellationReleased {
            await withCheckedContinuation { continuation in
                cancellationReleaseWaiters.append(continuation)
            }
        }

        let continuation = activeRun
        activeRun = nil
        continuation?.resume(throwing: CancellationError())
    }

    func waitUntilFirstRunIsSuspended() async {
        guard !firstRunIsSuspended else { return }
        await withCheckedContinuation { continuation in
            firstRunWaiters.append(continuation)
        }
    }

    func waitUntilCancellationIsRequested() async {
        guard !cancellationIsRequested else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func releaseCancellation() {
        cancellationReleased = true
        let waiters = cancellationReleaseWaiters
        cancellationReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func requestCount() -> Int { captured.count }
}

private actor ClaudeLifecycleCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private struct FixedClaudeSubscriptionChecker: ClaudeSubscriptionChecking {
    let status: ClaudeSubscriptionStatus

    func subscriptionStatus() async throws -> ClaudeSubscriptionStatus { status }
}

private actor SequencedClaudeSubscriptionChecker: ClaudeSubscriptionChecking {
    private var statuses: [ClaudeSubscriptionStatus]

    init(statuses: [ClaudeSubscriptionStatus]) {
        self.statuses = statuses
    }

    func subscriptionStatus() async throws -> ClaudeSubscriptionStatus {
        guard !statuses.isEmpty else { throw ClaudeSubscriptionError.invalidStatus }
        return statuses.removeFirst()
    }
}

private struct FixedClaudeGroundingPackBuilder: ClaudeGroundingPackBuilding {
    let pack: ClaudeGroundingPack

    func pack(
        for turn: ConversationTurn,
        snapshot: GroundingSnapshot
    ) async throws -> ClaudeGroundingPack {
        pack
    }
}

private actor RecordingClaudeEvidenceVerifier: MeetingEvidenceVerifying {
    private var count = 0

    func isFresh(_ snapshot: GroundingSnapshot) async -> Bool { true }

    func verifyAnswer(
        candidateSayNext: String,
        _ references: [EvidenceReference],
        groundingFingerprint: String,
        against snapshot: GroundingSnapshot
    ) async throws {
        count += 1
    }

    func verificationCount() -> Int { count }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private func XCTAssertThrowsClaudeMeetingError<T: Sendable>(
    _ expected: MeetingResponseError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected).", file: file, line: line)
    } catch let error as MeetingResponseError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected MeetingResponseError, received \(error).", file: file, line: line)
    }
}

private func XCTAssertClaudeTaskCancelled<T: Sendable>(
    _ task: Task<T, any Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await task.value
        XCTFail("Expected cancellation.", file: file, line: line)
    } catch is CancellationError {
        return
    } catch {
        XCTFail("Expected CancellationError, received \(error).", file: file, line: line)
    }
}
