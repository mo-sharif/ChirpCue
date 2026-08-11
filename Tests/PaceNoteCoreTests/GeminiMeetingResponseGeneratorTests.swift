import Foundation
import XCTest

@testable import PaceNoteCore

final class GeminiMeetingResponseGeneratorTests: XCTestCase {
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
            ]
        )
        let draft = try await generator.generateDeep(for: turn)
        XCTAssertEqual(draft.kind, .generalAnswer)
        XCTAssertEqual(
            draft.candidateSayNext,
            "I would start by clarifying which datasets and operations the connector actually needs.")

        let captured = await runner.capturedInput
        XCTAssertTrue(String(decoding: captured, as: UTF8.self).contains("secure MCP database access"))
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
