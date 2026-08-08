import Foundation
import XCTest

@testable import PaceNoteCore

final class ClaudeBinaryCompatibilityTests: XCTestCase {
    func testVersionParserAndTestedRange() throws {
        let installed = try XCTUnwrap(
            ClaudeBinaryVersion.parse("2.1.218 (Claude Code)\n")
        )
        XCTAssertEqual(installed, .init(major: 2, minor: 1, patch: 218))
        XCTAssertNoThrow(try ClaudeVersionPolicy.tested.validate(installed))
        XCTAssertNoThrow(
            try ClaudeVersionPolicy.tested.validate(
                .init(major: 2, minor: 1, patch: 999)
            )
        )

        XCTAssertThrowsError(
            try ClaudeVersionPolicy.tested.validate(
                .init(major: 2, minor: 1, patch: 217)
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeBinaryCompatibilityError,
                .incompatibleBinaryVersion
            )
        }
        XCTAssertThrowsError(
            try ClaudeVersionPolicy.tested.validate(
                .init(major: 2, minor: 2, patch: 0)
            )
        )
        XCTAssertThrowsError(
            try ClaudeVersionPolicy.tested.validate(
                .init(major: 2, minor: 1, patch: 218, prerelease: "beta.1")
            )
        )

        XCTAssertNil(ClaudeBinaryVersion.parse("Claude Code unknown"))
        XCTAssertNil(ClaudeBinaryVersion.parse("2.1"))
        XCTAssertNil(ClaudeBinaryVersion.parse("2.1.218.1"))
        XCTAssertNil(ClaudeBinaryVersion.parse("2.1.218-"))
    }

    func testOfficialLauncherResolvesToValidatedVersionedTarget() throws {
        let fixture = try ClaudeBinaryFixture()
        defer { fixture.remove() }

        let resolved = try ClaudeOfficialLauncherResolver.resolve(
            launcherURL: fixture.launcherURL,
            realHomeDirectory: fixture.homeDirectory,
            fileManager: .default,
            authenticityValidation: { candidate in
                guard candidate == fixture.executableURL else {
                    throw ClaudeBinaryTestError.unexpectedExecutable
                }
            }
        )

        XCTAssertEqual(resolved, fixture.executableURL)
        XCTAssertNotEqual(resolved, fixture.launcherURL)
        XCTAssertEqual(resolved.lastPathComponent, "2.1.218")
    }

    func testOfficialLauncherRejectsMutableOrSubstitutePaths() throws {
        let fixture = try ClaudeBinaryFixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try ClaudeOfficialLauncherResolver.resolve(
                launcherURL: fixture.executableURL,
                realHomeDirectory: fixture.homeDirectory,
                fileManager: .default,
                authenticityValidation: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeBinaryCompatibilityError,
                .launcherUnavailable
            )
        }

        let substitute = fixture.homeDirectory
            .appendingPathComponent("bin/claude", isDirectory: false)
        try FileManager.default.createDirectory(
            at: substitute.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: substitute,
            withDestinationURL: fixture.executableURL
        )
        XCTAssertThrowsError(
            try ClaudeOfficialLauncherResolver.resolve(
                launcherURL: substitute,
                realHomeDirectory: fixture.homeDirectory,
                fileManager: .default,
                authenticityValidation: { _ in }
            )
        )
    }

    func testOfficialLauncherRejectsTargetOutsideVersionStore() throws {
        let fixture = try ClaudeBinaryFixture()
        defer { fixture.remove() }
        let outside = fixture.homeDirectory.appendingPathComponent("outside-2.1.218")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: outside)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: outside.path
        )
        try FileManager.default.removeItem(at: fixture.launcherURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.launcherURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try ClaudeOfficialLauncherResolver.resolve(
                launcherURL: fixture.launcherURL,
                realHomeDirectory: fixture.homeDirectory,
                fileManager: .default,
                authenticityValidation: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeBinaryCompatibilityError,
                .launcherUnavailable
            )
        }
    }

    func testOfficialLauncherRejectsUntestedVersionBeforeExecution() throws {
        let fixture = try ClaudeBinaryFixture(version: "2.2.0")
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try ClaudeOfficialLauncherResolver.resolve(
                launcherURL: fixture.launcherURL,
                realHomeDirectory: fixture.homeDirectory,
                fileManager: .default,
                authenticityValidation: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeBinaryCompatibilityError,
                .incompatibleBinaryVersion
            )
        }
    }

    func testSignatureValidationFailureIsMappedFailClosed() throws {
        let fixture = try ClaudeBinaryFixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try ClaudeOfficialLauncherResolver.resolve(
                launcherURL: fixture.launcherURL,
                realHomeDirectory: fixture.homeDirectory,
                fileManager: .default,
                authenticityValidation: { _ in
                    throw ClaudeBinaryTestError.signatureRejected
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeBinaryCompatibilityError,
                .untrustedExecutable
            )
        }
    }

    func testResolverRejectsWritableVersionStoreOrExecutable() throws {
        let fixture = try ClaudeBinaryFixture()
        defer { fixture.remove() }
        let versionsRoot = fixture.executableURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: versionsRoot.path
        )

        XCTAssertThrowsError(
            try ClaudeOfficialLauncherResolver.resolve(
                launcherURL: fixture.launcherURL,
                realHomeDirectory: fixture.homeDirectory,
                fileManager: .default,
                authenticityValidation: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeBinaryCompatibilityError,
                .launcherUnavailable
            )
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: versionsRoot.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o722],
            ofItemAtPath: fixture.executableURL.path
        )
        XCTAssertThrowsError(
            try ClaudeOfficialLauncherResolver.resolve(
                launcherURL: fixture.launcherURL,
                realHomeDirectory: fixture.homeDirectory,
                fileManager: .default,
                authenticityValidation: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeBinaryCompatibilityError,
                .launcherUnavailable
            )
        }
    }

    func testTrustSnapshotDetectsExecutableReplacementBeforeLaunch() throws {
        let fixture = try ClaudeBinaryFixture()
        defer { fixture.remove() }
        let snapshot = try ClaudeExecutableTrustSnapshot.capture(
            fixture.executableURL,
            authenticityValidation: { _ in }
        )
        XCTAssertNoThrow(
            try snapshot.revalidate(authenticityValidation: { _ in })
        )

        try Data("#!/bin/sh\nprintf 'replacement'\n".utf8)
            .write(to: fixture.executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.executableURL.path
        )
        XCTAssertThrowsError(
            try snapshot.revalidate(authenticityValidation: { _ in })
        ) { error in
            XCTAssertEqual(
                error as? ClaudeBinaryCompatibilityError,
                .untrustedExecutable
            )
        }
    }

    func testAuthenticityPolicyRejectsUnsignedExecutable() {
        XCTAssertEqual(
            ClaudeBinaryAuthenticityValidator.anthropicTeamIdentifier,
            "Q6L2SF6YDW"
        )
        XCTAssertEqual(
            ClaudeBinaryAuthenticityValidator.claudeCodeSigningIdentifier,
            "com.anthropic.claude-code"
        )
        XCTAssertThrowsError(
            try ClaudeBinaryAuthenticityValidator.validate(
                URL(fileURLWithPath: "/bin/echo")
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeBinaryCompatibilityError,
                .untrustedExecutable
            )
        }
    }

    func testBinaryInspectorReadsVersionWithoutStartingAClaudeSession() async throws {
        let fixture = try ClaudeBinaryFixture()
        defer { fixture.remove() }

        let version = try await ClaudeBinaryInspector.inspect(
            executableURL: fixture.executableURL,
            environment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(version, .init(major: 2, minor: 1, patch: 218))
        XCTAssertNoThrow(try ClaudeVersionPolicy.tested.validate(version))
    }

    func testBinaryInspectorRejectsOutputThatDoesNotMatchVersionedTarget() async throws {
        let fixture = try ClaudeBinaryFixture(
            version: "2.1.218",
            reportedVersion: "2.1.219"
        )
        defer { fixture.remove() }

        do {
            _ = try await ClaudeBinaryInspector.inspect(
                executableURL: fixture.executableURL,
                environment: ["PATH": "/usr/bin:/bin"]
            )
            XCTFail("Expected the mismatched version output to fail closed.")
        } catch let error as ClaudeBinaryCompatibilityError {
            XCTAssertEqual(error, .untrustedExecutable)
        }
    }
}

private enum ClaudeBinaryTestError: Error {
    case signatureRejected
    case unexpectedExecutable
}

private struct ClaudeBinaryFixture: @unchecked Sendable {
    let root: URL
    let homeDirectory: URL
    let launcherURL: URL
    let executableURL: URL

    init(
        version: String = "2.1.218",
        reportedVersion: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        root =
            fileManager.temporaryDirectory
            .appendingPathComponent(
                "pacenote-claude-binary-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
        homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        launcherURL =
            homeDirectory
            .appendingPathComponent(".local/bin/claude", isDirectory: false)
        executableURL =
            homeDirectory
            .appendingPathComponent(
                ".local/share/claude/versions/\(version)",
                isDirectory: false
            )

        try fileManager.createDirectory(
            at: launcherURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(
            "#!/bin/sh\nprintf '\(reportedVersion ?? version) (Claude Code)\\n'\n".utf8
        )
        .write(to: executableURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
        try fileManager.createSymbolicLink(
            at: launcherURL,
            withDestinationURL: executableURL
        )
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: root)
    }
}
