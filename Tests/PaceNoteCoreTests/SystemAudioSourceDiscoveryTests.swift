import XCTest

@testable import PaceNoteCore

final class SystemAudioSourceDiscoveryTests: XCTestCase {
    func testMeetingSourcesSortFirstThenByNameAndPID() {
        let sources = [
            source(pid: 8, bundle: "com.apple.Music", name: "Music"),
            source(pid: 4, bundle: "com.google.Chrome", name: "Google Chrome"),
            source(pid: 2, bundle: "us.zoom.xos", name: "zoom.us"),
            source(pid: 3, bundle: "com.google.Chrome", name: "Google Chrome"),
            source(pid: 8, bundle: "duplicate", name: "Duplicate"),
        ]

        let sorted = SystemAudioSourceDiscovery.deduplicatedAndSorted(sources)

        XCTAssertEqual(sorted.map(\.processID), [3, 4, 2, 8])
        XCTAssertEqual(Set(sorted.map(\.processID)).count, sorted.count)
    }

    func testMeetingSourceClassifierCoversBrowsersAndNativeApps() {
        XCTAssertTrue(
            SystemAudioSourceDiscovery.isLikelyMeetingSource(
                name: "Google Chrome Helper",
                bundleID: "com.google.Chrome.helper"
            )
        )
        XCTAssertTrue(
            SystemAudioSourceDiscovery.isLikelyMeetingSource(
                name: "Microsoft Teams",
                bundleID: "com.microsoft.teams2"
            )
        )
        XCTAssertFalse(
            SystemAudioSourceDiscovery.isLikelyMeetingSource(
                name: "Music",
                bundleID: "com.apple.Music"
            )
        )
    }

    func testTransientProcessFailureDoesNotHideHealthySources() {
        let candidates: [Candidate] = [
            .source(source(pid: 10, bundle: "com.google.Chrome", name: "Chrome")),
            .inaccessible,
            .source(source(pid: 12, bundle: "us.zoom.xos", name: "Zoom")),
        ]

        let resolved = SystemAudioSourceDiscovery.resilientlyResolve(candidates) { candidate in
            switch candidate {
            case .source(let source): source
            case .inaccessible: throw CandidateFailure.inaccessible
            }
        }

        XCTAssertEqual(Set(resolved.map(\.processID)), [10, 12])
    }

    private func source(pid: Int32, bundle: String, name: String) -> SystemAudioSource {
        SystemAudioSource(
            processID: pid,
            bundleID: bundle,
            name: name,
            isLikelyMeetingSource: SystemAudioSourceDiscovery.isLikelyMeetingSource(
                name: name,
                bundleID: bundle
            )
        )
    }

    private enum Candidate {
        case source(SystemAudioSource)
        case inaccessible
    }

    private enum CandidateFailure: Error {
        case inaccessible
    }
}
