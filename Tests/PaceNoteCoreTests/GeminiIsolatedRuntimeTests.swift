import Foundation
import XCTest

@testable import PaceNoteCore

final class GeminiIsolatedRuntimeTests: XCTestCase {
    func testDeepArgumentsContainOnlyStaticInputAndRestrictiveAgentSelection() throws {
        let log = URL(fileURLWithPath: "/private/tmp/chirpcue-test.log")
        let arguments = try GeminiRuntimeArguments.deep(logFileURL: log)
        XCTAssertEqual(arguments.first, "-p")
        XCTAssertTrue(arguments.contains(GeminiRuntimeArguments.staticPrompt))
        XCTAssertTrue(arguments.contains("chirpcue"))
        XCTAssertTrue(arguments.contains("--disable-slash-commands"))
        XCTAssertTrue(arguments.contains("--sandbox"))
        XCTAssertTrue(arguments.contains("--json-schema"))
        XCTAssertFalse(arguments.joined(separator: " ").contains("meetingQuestion"))
    }

    func testEnvironmentUsesOnlyIsolatedHomeAndScrubsProviderCredentials() {
        let environment = GeminiRuntimeBuilder.sanitizedEnvironment(
            [
                "HOME": "/Users/private",
                "GOOGLE_API_KEY": "secret",
                "GEMINI_API_KEY": "secret",
                "HTTP_PROXY": "proxy",
                "LANG": "en_US.UTF-8",
            ],
            username: "person",
            isolatedHomeDirectory: URL(fileURLWithPath: "/private/profile"),
            temporaryDirectory: URL(fileURLWithPath: "/private/tmp")
        )
        XCTAssertEqual(environment["HOME"], "/private/profile")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertNil(environment["GOOGLE_API_KEY"])
        XCTAssertNil(environment["GEMINI_API_KEY"])
        XCTAssertNil(environment["HTTP_PROXY"])
    }

    func testVersionPolicyIsFailClosed() throws {
        XCTAssertEqual(
            GeminiBinaryVersion.parse("1.1.12\n"),
            GeminiBinaryVersion(major: 1, minor: 1, patch: 12)
        )
        XCTAssertNoThrow(
            try GeminiVersionPolicy.tested.validate(.init(major: 1, minor: 1, patch: 12))
        )
        XCTAssertThrowsError(
            try GeminiVersionPolicy.tested.validate(.init(major: 1, minor: 2, patch: 0))
        )
    }
}
