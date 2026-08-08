import Foundation
import XCTest

@testable import PaceNoteCore

final class ClaudeAuthStatusTests: XCTestCase {
    func testAcceptsOnlyFirstPartyClaudeSubscriptionAndRedactsIdentity() throws {
        let status = try ClaudeAuthStatusParser.parse(
            Data(
                #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"Person@Example.invalid","subscriptionType":"max","ignored":"value"}"#
                    .utf8
            )
        )

        XCTAssertEqual(status.planType, "max")
        XCTAssertEqual(status.redactedLabel, "p…@example.invalid")
        XCTAssertEqual(status.identityHash.count, 64)
        XCTAssertFalse(status.identityHash.contains("person"))
    }

    func testRejectsSignedOutAPIAndUnsupportedSubscriptionStates() throws {
        XCTAssertThrowsError(
            try ClaudeAuthStatusParser.parse(
                Data(#"{"loggedIn":false}"#.utf8)
            )
        ) { XCTAssertEqual($0 as? ClaudeSubscriptionError, .signedOut) }

        XCTAssertThrowsError(
            try ClaudeAuthStatusParser.parse(
                Data(
                    #"{"loggedIn":true,"authMethod":"apiKey","apiProvider":"firstParty","email":"person@example.invalid","subscriptionType":"max"}"#
                        .utf8
                )
            )
        ) { XCTAssertEqual($0 as? ClaudeSubscriptionError, .unsupportedAuthentication) }

        XCTAssertThrowsError(
            try ClaudeAuthStatusParser.parse(
                Data(
                    #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"person@example.invalid","subscriptionType":"console"}"#
                        .utf8
                )
            )
        ) { XCTAssertEqual($0 as? ClaudeSubscriptionError, .unsupportedSubscription) }

        for managedPlan in ["team", "enterprise"] {
            XCTAssertThrowsError(
                try ClaudeAuthStatusParser.parse(
                    Data(
                        """
                        {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"person@example.invalid","subscriptionType":"\(managedPlan)"}
                        """.utf8
                    )
                )
            ) { XCTAssertEqual($0 as? ClaudeSubscriptionError, .unsupportedSubscription) }
        }
    }

    func testRejectsMissingIdentityAndMalformedOrOversizedStatus() throws {
        XCTAssertThrowsError(
            try ClaudeAuthStatusParser.parse(
                Data(
                    #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro"}"#
                        .utf8
                )
            )
        ) { XCTAssertEqual($0 as? ClaudeSubscriptionError, .missingIdentity) }

        XCTAssertThrowsError(try ClaudeAuthStatusParser.parse(Data("not-json".utf8))) {
            XCTAssertEqual($0 as? ClaudeSubscriptionError, .invalidStatus)
        }
        XCTAssertThrowsError(try ClaudeAuthStatusParser.parse(Data(repeating: 65, count: 32 * 1_024 + 1))) {
            XCTAssertEqual($0 as? ClaudeSubscriptionError, .invalidStatus)
        }
    }

    func testCLIStatusCheckerUsesOnlyStatusCommandAndMapsNonzeroExit() async throws {
        let runner = RecordingClaudeRunner(
            result: ClaudeCommandResult(
                standardOutput: Data(
                    #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"person@example.invalid","subscriptionType":"pro"}"#
                        .utf8
                ),
                standardError: Data(),
                terminationStatus: 0
            )
        )
        let checker = ClaudeCLIAuthStatusChecker(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            currentDirectoryURL: URL(fileURLWithPath: "/tmp"),
            environment: ["HOME": "/Users/redacted"],
            runner: runner
        )

        let status = try await checker.subscriptionStatus()
        XCTAssertEqual(status.planType, "pro")
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].arguments, ["auth", "status", "--json"])
        XCTAssertTrue(requests[0].standardInput.isEmpty)
        XCTAssertEqual(requests[0].limits.maximumStandardInputBytes, 0)

        let failed = RecordingClaudeRunner(
            result: ClaudeCommandResult(
                standardOutput: Data(),
                standardError: Data("private failure".utf8),
                terminationStatus: 1
            )
        )
        let failedChecker = ClaudeCLIAuthStatusChecker(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            currentDirectoryURL: URL(fileURLWithPath: "/tmp"),
            environment: [:],
            runner: failed
        )
        do {
            _ = try await failedChecker.subscriptionStatus()
            XCTFail("Expected signed-out status.")
        } catch let error as ClaudeSubscriptionError {
            XCTAssertEqual(error, .signedOut)
            XCTAssertFalse(error.localizedDescription.contains("private failure"))
        }
    }
}

private actor RecordingClaudeRunner: ClaudeCommandRunning {
    let result: ClaudeCommandResult
    private(set) var requests: [ClaudeCommandRequest] = []

    init(result: ClaudeCommandResult) {
        self.result = result
    }

    func run(_ request: ClaudeCommandRequest) async throws -> ClaudeCommandResult {
        requests.append(request)
        return result
    }

    func cancelActive() async {}
}
