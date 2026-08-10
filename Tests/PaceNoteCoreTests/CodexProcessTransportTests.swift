import Darwin
import Foundation
import XCTest

@testable import PaceNoteCore

final class CodexProcessTransportTests: XCTestCase {
    func testStopWaitsForGracefulProcessExitAndIsIdempotent() async throws {
        let transport = CodexProcessTransport(
            configuration: CodexProcessTransportConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap 'exit 0' TERM; while :; do :; done"],
                terminationTimeout: .seconds(1),
                forceKillTimeout: .seconds(1),
                exitPollInterval: .milliseconds(5)
            )
        )
        try await transport.start()
        let startedPID = await transport.activeProcessIdentifier()
        let pid = try XCTUnwrap(startedPID)

        await transport.stop()
        await transport.stop()

        let activePID = await transport.activeProcessIdentifier()
        XCTAssertNil(activePID)
        assertProcessDoesNotExist(pid)
    }

    func testStopEscalatesAfterTermIgnoringProcessAndReapsPID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pacenote-process-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let readyMarker = root.appendingPathComponent("ready")
        let transport = CodexProcessTransport(
            configuration: CodexProcessTransportConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; printf ready > \"$PACENOTE_READY_MARKER\"; while :; do :; done",
                ],
                environment: ["PACENOTE_READY_MARKER": readyMarker.path],
                terminationTimeout: .milliseconds(100),
                forceKillTimeout: .seconds(1),
                exitPollInterval: .milliseconds(5)
            )
        )
        try await transport.start()
        let startedPID = await transport.activeProcessIdentifier()
        let pid = try XCTUnwrap(startedPID)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: readyMarker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyMarker.path))

        let clock = ContinuousClock()
        let startedStopping = clock.now
        await transport.stop()
        let elapsed = startedStopping.duration(to: clock.now)

        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(80))
        XCTAssertLessThan(elapsed, .seconds(1))
        let activePID = await transport.activeProcessIdentifier()
        XCTAssertNil(activePID)
        assertProcessDoesNotExist(pid)
    }

    func testPostLaunchAttestationFailsBeforeAnyProtocolInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pacenote-attestation-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("stdin-received")
        let probe = ProcessIDProbe()
        let transport = CodexProcessTransport(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "read value; printf received > \"$MARKER\""],
                environment: ["MARKER": marker.path],
                postLaunchValidator: { processID, _ in
                    probe.record(processID)
                    throw SpawnedProcessAttestationError.untrustedProcess
                }
            )
        )

        do {
            try await transport.start()
            XCTFail("Expected post-launch attestation rejection.")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .transportUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        assertProcessDoesNotExist(try XCTUnwrap(probe.value))
    }

    func testStopTerminatesDescendantsHoldingInheritedPipes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pacenote-process-tree-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let childPIDFile = root.appendingPathComponent("child-pid")
        let transport = CodexProcessTransport(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; /bin/sh -c 'trap \"\" TERM; while :; do sleep 1; done' & printf %s $! > \"$CHILD_PID_FILE\"; while :; do sleep 1; done",
                ],
                environment: ["CHILD_PID_FILE": childPIDFile.path],
                terminationTimeout: .milliseconds(100),
                forceKillTimeout: .seconds(1),
                exitPollInterval: .milliseconds(5)
            )
        )
        try await transport.start()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: childPIDFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let childPID = Int32(
            try String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let activeLeaderPID = await transport.activeProcessIdentifier()
        let leaderPID = try XCTUnwrap(activeLeaderPID)

        await transport.stop()

        assertProcessDoesNotExist(leaderPID)
        assertProcessDoesNotExist(try XCTUnwrap(childPID))
    }

    func testMalformedProtocolOutputTerminatesTheEntireProcessGroup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pacenote-malformed-process-tree-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let childPIDFile = root.appendingPathComponent("child-pid")
        let transport = CodexProcessTransport(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; /bin/sh -c 'trap \"\" TERM; while :; do sleep 1; done' & printf %s $! > \"$CHILD_PID_FILE\"; printf 'not-json\\n'; while :; do sleep 1; done",
                ],
                environment: ["CHILD_PID_FILE": childPIDFile.path]
            )
        )
        try await transport.start()
        let activeLeaderPID = await transport.activeProcessIdentifier()
        let leaderPID = try XCTUnwrap(activeLeaderPID)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: childPIDFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let childPID = try XCTUnwrap(
            Int32(
                try String(contentsOf: childPIDFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        for _ in 0..<100 {
            guard await transport.activeProcessIdentifier() != nil else { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        assertProcessDoesNotExist(leaderPID)
        assertProcessDoesNotExist(childPID)
    }

    private func assertProcessDoesNotExist(
        _ pid: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        errno = 0
        let result = Darwin.kill(pid, 0)
        XCTAssertEqual(result, -1, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }
}

private final class ProcessIDProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t?

    func record(_ processID: pid_t) {
        lock.withLock { self.processID = processID }
    }

    var value: pid_t? {
        lock.withLock { processID }
    }
}
