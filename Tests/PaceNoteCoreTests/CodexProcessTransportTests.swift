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
        let marker = root.appendingPathComponent("term-received")
        let transport = CodexProcessTransport(
            configuration: CodexProcessTransportConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap 'printf term > \"$PACENOTE_TEST_MARKER\"' TERM; while :; do :; done",
                ],
                environment: ["PACENOTE_TEST_MARKER": marker.path],
                terminationTimeout: .milliseconds(100),
                forceKillTimeout: .seconds(1),
                exitPollInterval: .milliseconds(5)
            )
        )
        try await transport.start()
        let startedPID = await transport.activeProcessIdentifier()
        let pid = try XCTUnwrap(startedPID)
        try await Task.sleep(for: .milliseconds(25))

        await transport.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let activePID = await transport.activeProcessIdentifier()
        XCTAssertNil(activePID)
        assertProcessDoesNotExist(pid)
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
