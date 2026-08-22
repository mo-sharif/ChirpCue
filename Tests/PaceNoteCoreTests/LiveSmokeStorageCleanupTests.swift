import Foundation
import XCTest

final class LiveSmokeStorageCleanupTests: XCTestCase {
    func testRemovesOwnedRootAndEmptySharedParent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ownedRoot = try fixture.makeOwnedRoot(named: "one")
        try Data("fixture".utf8).write(to: ownedRoot.appendingPathComponent("input.json"))

        try LiveSmokeStorageCleanup.removeOwnedRoot(
            ownedRoot,
            applicationRoot: fixture.applicationRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.smokeTestsRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.meetingsRoot.path))
    }

    func testPreservesSharedParentAndSiblingFixture() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ownedRoot = try fixture.makeOwnedRoot(named: "one")
        let sibling = try fixture.makeOwnedRoot(named: "two")

        try LiveSmokeStorageCleanup.removeOwnedRoot(
            ownedRoot,
            applicationRoot: fixture.applicationRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.smokeTestsRoot.path))
    }

    func testRejectsRootOutsideDirectSmokeTestsChildren() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let unrelated = fixture.meetingsRoot.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unrelated,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        XCTAssertThrowsError(
            try LiveSmokeStorageCleanup.removeOwnedRoot(
                unrelated,
                applicationRoot: fixture.applicationRoot
            )
        ) { error in
            XCTAssertEqual(error as? LiveSmokeStorageCleanupError, .invalidOwnedRoot)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}

private final class Fixture {
    let root: URL
    let applicationRoot: URL
    let meetingsRoot: URL
    let smokeTestsRoot: URL

    init(fileManager: FileManager = .default) throws {
        root =
            fileManager.temporaryDirectory
            .appendingPathComponent("live-smoke-storage-cleanup-\(UUID().uuidString)", isDirectory: true)
        applicationRoot = root.appendingPathComponent("PaceNote", isDirectory: true)
        meetingsRoot = applicationRoot.appendingPathComponent("Meetings", isDirectory: true)
        smokeTestsRoot = meetingsRoot.appendingPathComponent("SmokeTests", isDirectory: true)
        try fileManager.createDirectory(
            at: meetingsRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func makeOwnedRoot(named name: String, fileManager: FileManager = .default) throws -> URL {
        let ownedRoot = smokeTestsRoot.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(
            at: ownedRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return ownedRoot
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: root)
    }
}
