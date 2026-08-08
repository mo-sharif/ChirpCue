import Foundation
import XCTest

@testable import PaceNoteCore

/// Opt-in, authentication-only proof for the real first-party Claude.ai subscription path.
///
/// This smoke checks the signed Claude executable, its tested version, and `auth status`.
/// It never starts a model turn, so it performs no paid inference.
final class ClaudeSubscriptionAuthSmokeTests: XCTestCase {
    private static let optInEnvironmentKey = "PACENOTE_RUN_CLAUDE_AUTH_SMOKE"

    func testFirstPartyClaudeSubscriptionAuthenticationWithoutGeneration() async throws {
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.optInEnvironmentKey)=1 to run the authentication-only Claude subscription smoke."
            )
        }

        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL
        let runtimeRoot =
            temporaryRoot
            .appendingPathComponent(
                "ChirpCue-Claude-Auth-Smoke-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
        defer {
            // The UUID-named runtime root is the only path this smoke owns.
            try? fileManager.removeItem(at: runtimeRoot)
        }

        let runtime = try ClaudeRuntimeBuilder.prepare(
            runtimeRoot: runtimeRoot,
            realHomeDirectory: fileManager.homeDirectoryForCurrentUser,
            fileManager: fileManager
        )

        try runtime.revalidateExecutable()
        let version = try await ClaudeBinaryInspector.inspect(
            executableURL: runtime.executableURL,
            environment: runtime.processEnvironment
        )
        try ClaudeVersionPolicy.tested.validate(version)

        try runtime.revalidateExecutable()
        let checker = ClaudeCLIAuthStatusChecker(
            executableURL: runtime.executableURL,
            currentDirectoryURL: runtime.workingDirectory,
            environment: runtime.processEnvironment
        )
        let status = try await checker.subscriptionStatus()

        XCTAssertTrue(["pro", "max"].contains(status.planType))
        XCTAssertFalse(status.redactedLabel.isEmpty)
        XCTAssertEqual(status.identityHash.utf8.count, 64)
        XCTAssertTrue(
            status.identityHash.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
        )
    }
}
