import Foundation
import XCTest

@testable import PaceNoteCore

final class GeminiAuthStatusTests: XCTestCase {
    func testParsesSupportedGeminiModelsWithoutAccountIdentity() throws {
        let status = try GeminiModelListParser.parse(
            Data("Available models:\n  gemini-3-pro\n  gemini-3-flash\n".utf8)
        )
        XCTAssertEqual(status.planType, "Google AI")
        XCTAssertEqual(status.redactedLabel, "Google account")
        XCTAssertEqual(status.modelIDs, ["gemini-3-flash", "gemini-3-pro"])
    }

    func testRejectsSignedOutMissingAndOversizedStatus() throws {
        XCTAssertThrowsError(
            try GeminiModelListParser.parse(Data("Error: Please sign in to continue".utf8))
        ) { XCTAssertEqual($0 as? GeminiSubscriptionError, .signedOut) }
        XCTAssertThrowsError(try GeminiModelListParser.parse(Data("no models".utf8))) {
            XCTAssertEqual($0 as? GeminiSubscriptionError, .noSupportedModels)
        }
        XCTAssertThrowsError(
            try GeminiModelListParser.parse(Data(repeating: 65, count: 32 * 1_024 + 1))
        ) { XCTAssertEqual($0 as? GeminiSubscriptionError, .invalidStatus) }
    }

    func testCheckerUsesOnlyBoundedModelsCommand() async throws {
        let runner = GeminiRecordingRunner(
            result: ClaudeCommandResult(
                standardOutput: Data("gemini-3-pro\n".utf8),
                standardError: Data(),
                terminationStatus: 0
            )
        )
        let checker = GeminiCLIAuthStatusChecker(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            currentDirectoryURL: URL(fileURLWithPath: "/tmp"),
            environment: ["HOME": "/private/redacted"],
            runner: runner
        )
        _ = try await checker.subscriptionStatus()
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].arguments, ["models"])
        XCTAssertTrue(requests[0].standardInput.isEmpty)
        XCTAssertEqual(requests[0].limits.maximumStandardInputBytes, 0)
    }
}

private actor GeminiRecordingRunner: ClaudeCommandRunning {
    let result: ClaudeCommandResult
    private(set) var requests: [ClaudeCommandRequest] = []

    init(result: ClaudeCommandResult) { self.result = result }

    func run(_ request: ClaudeCommandRequest) async throws -> ClaudeCommandResult {
        requests.append(request)
        return result
    }

    func cancelActive() async {}
}
