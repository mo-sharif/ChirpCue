import Foundation
import XCTest

@testable import PaceNoteCore

final class GeminiSubscriptionAuthSmokeTests: XCTestCase {
    func testGoogleSubscriptionAuthenticationWithoutGeneration() async throws {
        guard ProcessInfo.processInfo.environment["PACENOTE_RUN_GEMINI_AUTH_SMOKE"] == "1" else {
            throw XCTSkip(
                "Set PACENOTE_RUN_GEMINI_AUTH_SMOKE=1 to run the authentication-only Google AI smoke."
            )
        }
        let runtimeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChirpCueGeminiAuthSmoke-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let runtime = try GeminiRuntimeBuilder.prepare(runtimeRoot: runtimeRoot)
        let version = try await GeminiBinaryInspector.inspect(
            executableURL: runtime.executableURL,
            currentDirectoryURL: runtime.workingDirectory,
            environment: runtime.processEnvironment
        )
        try GeminiVersionPolicy.tested.validate(version)
        try runtime.revalidateExecutable()
        let status = try await GeminiCLIAuthStatusChecker(
            executableURL: runtime.executableURL,
            currentDirectoryURL: runtime.workingDirectory,
            environment: runtime.processEnvironment
        ).subscriptionStatus()

        XCTAssertFalse(status.modelIDs.isEmpty)
        XCTAssertEqual(status.redactedLabel, "Google account")
    }
}
