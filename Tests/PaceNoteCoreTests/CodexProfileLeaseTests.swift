import Darwin
import Foundation
import XCTest

@testable import PaceNoteCore

final class CodexProfileLeaseTests: XCTestCase {
    func testExclusiveLeaseBlocksSecondOwnerAndCanBeReacquiredAfterRelease() throws {
        let fixture = try ProfileLeaseFixture()
        defer { fixture.remove() }

        var first: CodexProfileLease? = try CodexProfileLease.acquire(
            profileRoot: fixture.profileRoot
        )
        XCTAssertNotNil(first)
        XCTAssertThrowsError(
            try CodexProfileLease.acquire(profileRoot: fixture.profileRoot)
        ) { error in
            XCTAssertEqual(error as? CodexProfileLeaseError, .alreadyInUse)
        }

        first = nil
        XCTAssertNoThrow(
            try CodexProfileLease.acquire(profileRoot: fixture.profileRoot)
        )

        let lockURL = fixture.profilesRoot.appendingPathComponent(".personal.lock")
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        let mode = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        var status = stat()
        XCTAssertEqual(lstat(lockURL.path, &status), 0)
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(status.st_nlink, 1)
    }

    func testRejectsSymlinkedProfilesRoot() throws {
        let fixture = try ProfileLeaseFixture(createProfilesRoot: false)
        defer { fixture.remove() }
        let realProfilesRoot = fixture.root.appendingPathComponent("real-profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realProfilesRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.profilesRoot,
            withDestinationURL: realProfilesRoot
        )

        XCTAssertThrowsError(
            try CodexProfileLease.acquire(profileRoot: fixture.profileRoot)
        ) { error in
            XCTAssertEqual(error as? CodexProfileLeaseError, .invalidProfileRoot)
        }
    }

    func testRejectsSymlinkedLockFileWithoutTouchingItsTarget() throws {
        let fixture = try ProfileLeaseFixture()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("lock-target")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.lockURL,
            withDestinationURL: target
        )

        XCTAssertThrowsError(
            try CodexProfileLease.acquire(profileRoot: fixture.profileRoot)
        ) { error in
            XCTAssertEqual(error as? CodexProfileLeaseError, .invalidLockFile)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("unchanged".utf8))
    }

    func testRejectsHardLinkedLockFile() throws {
        let fixture = try ProfileLeaseFixture()
        defer { fixture.remove() }
        let original = fixture.root.appendingPathComponent("original-lock")
        XCTAssertTrue(FileManager.default.createFile(atPath: original.path, contents: Data()))
        XCTAssertEqual(link(original.path, fixture.lockURL.path), 0)

        XCTAssertThrowsError(
            try CodexProfileLease.acquire(profileRoot: fixture.profileRoot)
        ) { error in
            XCTAssertEqual(error as? CodexProfileLeaseError, .invalidLockFile)
        }
    }
}

private final class ProfileLeaseFixture {
    let root: URL
    let profilesRoot: URL
    let profileRoot: URL
    var lockURL: URL { profilesRoot.appendingPathComponent(".personal.lock") }

    init(createProfilesRoot: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pacenote-profile-lease-\(UUID().uuidString)",
            isDirectory: true
        )
        profilesRoot = root.appendingPathComponent("Profiles", isDirectory: true)
        profileRoot = profilesRoot.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        if createProfilesRoot {
            try FileManager.default.createDirectory(
                at: profilesRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
