import Foundation
import XCTest

@testable import PaceNoteCore

final class GeminiMeetingResponseGeneratorTests: XCTestCase {
    func testLateFailedPreparationWaiterCannotDeleteRetryRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChirpCueGeminiPrepareRace-\(UUID().uuidString)",
            isDirectory: true
        )
        let meetingRoot = root.appendingPathComponent("meeting", isDirectory: true)
        let runtimeRoot = meetingRoot.appendingPathComponent("gemini-runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("agy", isDirectory: false)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: executable.path,
                contents: Data("test".utf8),
                attributes: [.posixPermissions: 0o700]
            )
        )
        let trust = try GeminiExecutableTrustSnapshot.capture(executable) { _ in }
        let staleWaiterGate = GeminiTestGate()
        let retryVerifierGate = GeminiTestGate()
        let failureProbe = GeminiPreparationFailureProbe(staleWaiterGate: staleWaiterGate)
        let versionSequence = GeminiVersionSequence(retryGate: retryVerifierGate)
        let status = GeminiSubscriptionStatus(
            planType: "Google AI",
            redactedLabel: "Google account",
            modelIDs: ["gemini-3-pro"]
        )
        let generator = GeminiMeetingResponseGenerator(
            configuration: GeminiMeetingResponseConfiguration(
                meetingID: UUID(),
                meetingPrivateRoot: meetingRoot,
                groundingSnapshot: nil
            ),
            runner: GeminiGeneratorRunner(
                inputURL: runtimeRoot.appendingPathComponent("work/input.json"),
                result: ClaudeCommandResult(
                    standardOutput: Data(),
                    standardError: Data(),
                    terminationStatus: 0
                )
            ),
            subscriptionChecker: FixedGeminiChecker(status: status),
            runtimePreparer: { _ in
                let profileRoot = runtimeRoot.appendingPathComponent("home", isDirectory: true)
                let work = runtimeRoot.appendingPathComponent("work", isDirectory: true)
                let temporary = runtimeRoot.appendingPathComponent("tmp", isDirectory: true)
                for directory in [runtimeRoot, profileRoot, work, temporary] {
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                }
                let inputURL = work.appendingPathComponent("input.json", isDirectory: false)
                if !FileManager.default.fileExists(atPath: inputURL.path) {
                    guard
                        FileManager.default.createFile(
                            atPath: inputURL.path,
                            contents: Data(),
                            attributes: [.posixPermissions: 0o600]
                        )
                    else {
                        throw GeminiPreparationTestError.cannotCreateInput
                    }
                }
                return GeminiIsolatedRuntime(
                    executableURL: executable,
                    executableTrustSnapshot: trust,
                    runtimeRoot: runtimeRoot,
                    isolatedHomeDirectory: profileRoot,
                    workingDirectory: work,
                    temporaryDirectory: temporary,
                    inputURL: inputURL,
                    processArguments: ["-p", GeminiRuntimeArguments.staticPrompt, "--agent", "chirpcue"],
                    processEnvironment: ["HOME": profileRoot.path]
                )
            },
            versionVerifier: { _ in try await versionSequence.verify() },
            executableRevalidator: { _ in }
        )
        await generator.setPreparationFailureResumedTestHook { preparationID in
            await failureProbe.record(preparationID)
        }

        let first = Task {
            do {
                _ = try await generator.prepare()
                return false
            } catch {
                return true
            }
        }
        let second = Task {
            do {
                _ = try await generator.prepare()
                return false
            } catch {
                return true
            }
        }

        await staleWaiterGate.waitUntilSuspended()
        let retry = Task { try await generator.prepare() }
        await retryVerifierGate.waitUntilSuspended()
        await staleWaiterGate.release()

        let firstFailed = await first.value
        let secondFailed = await second.value
        XCTAssertTrue(firstFailed)
        XCTAssertTrue(secondFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeRoot.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtimeRoot.appendingPathComponent("work/input.json").path
            )
        )

        await retryVerifierGate.release()
        let prepared = try await retry.value
        XCTAssertEqual(prepared.planType, "Google AI")
        let cleanup = await generator.shutdown()
        XCTAssertTrue(cleanup.failures.isEmpty)
    }

    func testUsesFileOnlyPayloadAndReturnsValidatedGeneralAnswer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChirpCueGeminiTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let meetingRoot = root.appendingPathComponent("meeting", isDirectory: true)
        let runtimeRoot = meetingRoot.appendingPathComponent("gemini-runtime", isDirectory: true)
        let profileRoot = runtimeRoot.appendingPathComponent("home", isDirectory: true)
        let work = runtimeRoot.appendingPathComponent("work", isDirectory: true)
        let temporary = runtimeRoot.appendingPathComponent("tmp", isDirectory: true)
        for directory in [root, meetingRoot, profileRoot, runtimeRoot, work, temporary] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("agy", isDirectory: false)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: executable.path,
                contents: Data("test".utf8),
                attributes: [.posixPermissions: 0o700]
            )
        )
        let trust = try GeminiExecutableTrustSnapshot.capture(executable) { _ in }
        let inputURL = work.appendingPathComponent("input.json", isDirectory: false)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: inputURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        )
        let runtime = GeminiIsolatedRuntime(
            executableURL: executable,
            executableTrustSnapshot: trust,
            runtimeRoot: runtimeRoot,
            isolatedHomeDirectory: profileRoot,
            workingDirectory: work,
            temporaryDirectory: temporary,
            inputURL: inputURL,
            processArguments: ["-p", GeminiRuntimeArguments.staticPrompt, "--agent", "chirpcue"],
            processEnvironment: ["HOME": profileRoot.path]
        )
        let meetingID = UUID()
        let turnID = UUID()
        let response = try output(turnID: turnID)
        let runner = GeminiGeneratorRunner(inputURL: inputURL, result: response)
        let status = GeminiSubscriptionStatus(
            planType: "Google AI",
            redactedLabel: "Google account",
            modelIDs: ["gemini-3-pro"]
        )
        let generator = GeminiMeetingResponseGenerator(
            configuration: GeminiMeetingResponseConfiguration(
                meetingID: meetingID,
                meetingPrivateRoot: meetingRoot,
                groundingSnapshot: nil
            ),
            runner: runner,
            subscriptionChecker: FixedGeminiChecker(status: status),
            runtimePreparer: { _ in runtime },
            versionVerifier: { _ in },
            executableRevalidator: { _ in }
        )

        let prepared = try await generator.prepare()
        XCTAssertEqual(prepared.planType, "Google AI")
        let turn = ConversationTurn(
            identity: TurnIdentity(
                meetingID: meetingID,
                turnID: turnID,
                generation: 1
            ),
            question: "How should we secure MCP database access?",
            recentTranscript: [
                TranscriptSegment(
                    source: .them,
                    text: "What is the access plan?",
                    startedAt: 1,
                    endedAt: 2,
                    isFinal: true
                )
            ],
            speakerBrief: "Eight years with React; lately building TypeScript AI products."
        )
        let quick = try await generator.generateQuick(for: turn)
        let draft = try await generator.generateDeep(for: turn)
        XCTAssertEqual(
            quick.sayNow,
            "I'd start by clarifying the goal and constraints, then walk through the tradeoffs before committing to an approach."
        )
        XCTAssertEqual(draft.kind, .generalAnswer)
        XCTAssertEqual(
            draft.candidateSayNext,
            "I would start by clarifying which datasets and operations the connector actually needs.")

        let captured = await runner.capturedInput
        let capturedText = String(decoding: captured, as: UTF8.self)
        XCTAssertTrue(capturedText.contains("secure MCP database access"))
        XCTAssertTrue(capturedText.contains("Eight years with React"))
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests[0].arguments.joined().contains("secure MCP database access"))
        XCTAssertTrue(requests[0].standardInput.isEmpty)
        XCTAssertTrue((try Data(contentsOf: inputURL)).isEmpty)
        let cleanup = await generator.shutdown()
        XCTAssertTrue(cleanup.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeRoot.path))
    }

    private func output(turnID: UUID) throws -> ClaudeCommandResult {
        let draft: [String: Any] = [
            "turnID": turnID.uuidString,
            "generation": 1,
            "groundingFingerprint": NSNull(),
            "kind": "general_answer",
            "candidateSayNext":
                "I would start by clarifying which datasets and operations the connector actually needs.",
            "confidence": 0.8,
            "basis": [],
            "missingEvidence": [],
        ]
        return ClaudeCommandResult(
            standardOutput: try JSONSerialization.data(
                withJSONObject: ["status": "SUCCESS", "response": draft, "num_turns": 1]
            ),
            standardError: Data(),
            terminationStatus: 0
        )
    }
}

private enum GeminiPreparationTestError: Error {
    case firstAttempt
    case cannotCreateInput
}

private actor GeminiVersionSequence {
    private let retryGate: GeminiTestGate
    private var calls = 0

    init(retryGate: GeminiTestGate) {
        self.retryGate = retryGate
    }

    func verify() async throws {
        calls += 1
        if calls == 1 {
            throw GeminiPreparationTestError.firstAttempt
        }
        await retryGate.suspend()
    }
}

private actor GeminiPreparationFailureProbe {
    private let staleWaiterGate: GeminiTestGate
    private var preparationID: UUID?
    private var resumes = 0

    init(staleWaiterGate: GeminiTestGate) {
        self.staleWaiterGate = staleWaiterGate
    }

    func record(_ preparationID: UUID) async {
        if let expected = self.preparationID {
            precondition(expected == preparationID)
        } else {
            self.preparationID = preparationID
        }
        resumes += 1
        if resumes == 2 {
            await staleWaiterGate.suspend()
        }
    }
}

private actor GeminiTestGate {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        suspended = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private struct FixedGeminiChecker: GeminiSubscriptionChecking {
    let status: GeminiSubscriptionStatus
    func subscriptionStatus() async throws -> GeminiSubscriptionStatus { status }
}

private actor GeminiGeneratorRunner: ClaudeCommandRunning {
    let inputURL: URL
    let result: ClaudeCommandResult
    private(set) var requests: [ClaudeCommandRequest] = []
    private(set) var capturedInput = Data()

    init(inputURL: URL, result: ClaudeCommandResult) {
        self.inputURL = inputURL
        self.result = result
    }

    func run(_ request: ClaudeCommandRequest) async throws -> ClaudeCommandResult {
        requests.append(request)
        capturedInput = try Data(contentsOf: inputURL)
        return result
    }

    func cancelActive() async {}
}
