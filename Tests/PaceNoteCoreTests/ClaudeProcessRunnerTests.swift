import Darwin
import Foundation
import XCTest

@testable import PaceNoteCore

final class ClaudeProcessRunnerTests: XCTestCase {
    func testPipesBoundedInputAndUsesExplicitWorkingDirectoryAndEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-claude-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ClaudeProcessRunner()
        let result = try await runner.run(
            ClaudeCommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                currentDirectoryURL: root,
                arguments: ["-c", "pwd; IFS= read -r value || true; printf '%s' \"$value\""],
                environment: ["PATH": "/usr/bin:/bin"],
                standardInput: Data("private prompt".utf8)
            )
        )

        XCTAssertEqual(result.terminationStatus, 0)
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        let outputLines = output.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(outputLines.count, 2)
        let reportedWorkingDirectory = String(outputLines[0])
        let expectedAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let reportedAttributes = try FileManager.default.attributesOfItem(atPath: reportedWorkingDirectory)
        XCTAssertEqual(
            expectedAttributes[.systemNumber] as? NSNumber,
            reportedAttributes[.systemNumber] as? NSNumber
        )
        XCTAssertEqual(
            expectedAttributes[.systemFileNumber] as? NSNumber,
            reportedAttributes[.systemFileNumber] as? NSNumber
        )
        XCTAssertEqual(outputLines[1], "private prompt")
        XCTAssertTrue(result.standardError.isEmpty)
    }

    func testRejectsOversizedInputBeforeLaunch() async throws {
        let runner = ClaudeProcessRunner()
        do {
            _ = try await runner.run(
                ClaudeCommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/echo"),
                    currentDirectoryURL: URL(fileURLWithPath: "/tmp"),
                    arguments: [],
                    environment: [:],
                    standardInput: Data(repeating: 65, count: 2),
                    limits: ClaudeCommandLimits(
                        timeout: .seconds(1),
                        maximumStandardInputBytes: 1,
                        maximumStandardOutputBytes: 100,
                        maximumStandardErrorBytes: 100
                    )
                )
            )
            XCTFail("Expected input limit rejection.")
        } catch let error as ClaudeCommandError {
            XCTAssertEqual(error, .inputLimitExceeded)
        }
    }

    func testPostLaunchAttestationRejectsBeforeWritingSensitiveInput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacenote-claude-attestation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("stdin-received")
        let probe = ClaudeProcessIDProbe()
        let runner = ClaudeProcessRunner()

        do {
            _ = try await runner.run(
                ClaudeCommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    currentDirectoryURL: root,
                    arguments: ["-c", "read value; printf received > \"$MARKER\""],
                    environment: ["MARKER": marker.path, "PATH": "/usr/bin:/bin"],
                    standardInput: Data("sensitive meeting prompt".utf8),
                    postLaunchValidator: { processID, _ in
                        probe.record(processID)
                        throw SpawnedProcessAttestationError.untrustedProcess
                    }
                )
            )
            XCTFail("Expected post-launch attestation rejection.")
        } catch let error as ClaudeCommandError {
            XCTAssertEqual(error, .launchFailed)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let processID = try XCTUnwrap(probe.value)
        errno = 0
        XCTAssertEqual(Darwin.kill(processID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testTerminatesOnOutputLimit() async throws {
        let runner = ClaudeProcessRunner()
        do {
            _ = try await runner.run(
                ClaudeCommandRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
                    currentDirectoryURL: URL(fileURLWithPath: "/tmp"),
                    arguments: [],
                    environment: ["PATH": "/usr/bin:/bin"],
                    limits: ClaudeCommandLimits(
                        timeout: .seconds(2),
                        maximumStandardInputBytes: 0,
                        maximumStandardOutputBytes: 1_024,
                        maximumStandardErrorBytes: 1_024,
                        terminationGracePeriod: .milliseconds(100)
                    )
                )
            )
            XCTFail("Expected output limit rejection.")
        } catch let error as ClaudeCommandError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
    }

    func testCancellationTerminatesAndReapsLongRunningProcess() async throws {
        let runner = ClaudeProcessRunner()
        let task = Task {
            try await runner.run(
                ClaudeCommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    currentDirectoryURL: URL(fileURLWithPath: "/tmp"),
                    arguments: ["30"],
                    environment: ["PATH": "/usr/bin:/bin"],
                    limits: ClaudeCommandLimits(
                        timeout: .seconds(35),
                        maximumStandardInputBytes: 0,
                        maximumStandardOutputBytes: 100,
                        maximumStandardErrorBytes: 100,
                        terminationGracePeriod: .milliseconds(100)
                    )
                )
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        await runner.cancelActive()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCancellationTerminatesDescendantProcessGroup() async throws {
        let fixture = try ClaudeDescendantFixture()
        defer { fixture.remove() }
        let runner = ClaudeProcessRunner()
        let request = fixture.request(
            command: """
                trap '' TERM
                (trap '' TERM; while :; do sleep 30; done) &
                child=$!
                printf '%s' "$child" > "$1"
                wait "$child"
                """,
            timeout: .seconds(30)
        )
        let task = Task {
            try await runner.run(request)
        }
        let descendant = try await fixture.waitForDescendantPID()

        await runner.cancelActive()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }
        let descendantWasTerminated = await fixture.waitUntilProcessIsGone(descendant)
        XCTAssertTrue(
            descendantWasTerminated,
            "Cancellation must terminate the entire spawned process group."
        )
    }

    func testTimeoutTerminatesDescendantProcessGroup() async throws {
        let fixture = try ClaudeDescendantFixture()
        defer { fixture.remove() }
        let runner = ClaudeProcessRunner()
        let request = fixture.request(
            command: """
                trap '' TERM
                (trap '' TERM; while :; do sleep 30; done) &
                child=$!
                printf '%s' "$child" > "$1"
                wait "$child"
                """,
            timeout: .milliseconds(250)
        )
        let task = Task {
            try await runner.run(request)
        }
        let descendant = try await fixture.waitForDescendantPID()

        do {
            _ = try await task.value
            XCTFail("Expected timeout.")
        } catch let error as ClaudeCommandError {
            XCTAssertEqual(error, .timedOut)
        }
        let descendantWasTerminated = await fixture.waitUntilProcessIsGone(descendant)
        XCTAssertTrue(
            descendantWasTerminated,
            "Timeout must terminate the entire spawned process group."
        )
    }

    func testSuccessfulLeaderExitCleansDescendantHoldingInheritedPipes() async throws {
        let fixture = try ClaudeDescendantFixture()
        defer { fixture.remove() }
        let runner = ClaudeProcessRunner()
        let clock = ContinuousClock()
        let started = clock.now

        let result = try await runner.run(
            fixture.request(
                command: """
                    (trap '' TERM; while :; do sleep 30; done) &
                    child=$!
                    printf '%s' "$child" > "$1"
                    exit 0
                    """,
                timeout: .seconds(5)
            )
        )
        let elapsed = started.duration(to: clock.now)
        let descendant = try fixture.descendantPID()
        let descendantWasTerminated = await fixture.waitUntilProcessIsGone(descendant)

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertLessThan(elapsed, .seconds(3))
        XCTAssertTrue(
            descendantWasTerminated,
            "A descendant retaining stdout or stderr must not outlive a completed request."
        )
    }
}

private final class ClaudeProcessIDProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t?

    func record(_ processID: pid_t) {
        lock.withLock { self.processID = processID }
    }

    var value: pid_t? {
        lock.withLock { processID }
    }
}

private final class ClaudeDescendantFixture {
    let root: URL
    private let pidFile: URL

    init(fileManager: FileManager = .default) throws {
        root =
            fileManager.temporaryDirectory
            .appendingPathComponent(
                "pacenote-claude-descendant-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
        pidFile = root.appendingPathComponent("descendant.pid", isDirectory: false)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func request(command: String, timeout: Duration) -> ClaudeCommandRequest {
        ClaudeCommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            currentDirectoryURL: root,
            arguments: ["-c", command, "fixture", pidFile.path],
            environment: ["PATH": "/usr/bin:/bin"],
            limits: ClaudeCommandLimits(
                timeout: timeout,
                maximumStandardInputBytes: 0,
                maximumStandardOutputBytes: 1_024,
                maximumStandardErrorBytes: 1_024,
                terminationGracePeriod: .milliseconds(100)
            )
        )
    }

    func waitForDescendantPID() async throws -> pid_t {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let processID = try? descendantPID() { return processID }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClaudeDescendantFixtureError.missingProcessID
    }

    func descendantPID() throws -> pid_t {
        let value = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let processID = pid_t(value), processID > 0 else {
            throw ClaudeDescendantFixtureError.invalidProcessID
        }
        return processID
    }

    func waitUntilProcessIsGone(_ processID: pid_t) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if !Self.processExists(processID) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !Self.processExists(processID)
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: root)
    }

    private static func processExists(_ processID: pid_t) -> Bool {
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }
}

private enum ClaudeDescendantFixtureError: Error {
    case missingProcessID
    case invalidProcessID
}
