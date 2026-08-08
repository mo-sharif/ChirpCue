import CoreAudio
import PaceNoteCore
import XCTest

@testable import PaceNoteApp

final class PaceNoteRuntimeOutputSourceTests: XCTestCase {
    func testChromeProcessesArePresentedAndCapturedAsOneApplication() throws {
        let chromeSources = [
            source(
                processID: 101,
                bundleID: "com.google.Chrome",
                audioObjectID: 11,
                name: "Google Chrome"
            ),
            source(
                processID: 102,
                bundleID: "com.google.Chrome.helper",
                audioObjectID: 12,
                name: "Google Chrome Helper"
            ),
            source(
                processID: 103,
                bundleID: "com.google.Chrome.helper",
                audioObjectID: 13,
                name: "Google Chrome Helper"
            ),
        ]
        let zoom = SystemAudioSource(
            processID: 201,
            bundleID: "us.zoom.xos",
            processStartToken: "201:1",
            audioObjectID: 21,
            name: "zoom.us",
            isLikelyMeetingSource: true,
            owningApplicationBundleID: "us.zoom.xos",
            owningApplicationName: "zoom.us"
        )

        let groups = PaceNoteRuntime.groupedOutputSources(chromeSources + [zoom])
        let chrome = try XCTUnwrap(groups.first { $0.option.name == "Google Chrome" })

        XCTAssertEqual(chrome.option.detail, "com.google.Chrome")
        XCTAssertEqual(chrome.sources.map(\.processID), [101, 102, 103])
        XCTAssertEqual(groups.count, 2)

        let reordered = PaceNoteRuntime.groupedOutputSources([zoom] + chromeSources.reversed())
        let reorderedChrome = try XCTUnwrap(
            reordered.first { $0.option.name == "Google Chrome" }
        )
        XCTAssertEqual(reorderedChrome.option.id, chrome.option.id)
        XCTAssertEqual(reorderedChrome.sources.map(\.processID), [101, 102, 103])
    }

    private func source(
        processID: Int32,
        bundleID: String,
        audioObjectID: AudioObjectID,
        name: String
    ) -> SystemAudioSource {
        SystemAudioSource(
            processID: processID,
            bundleID: bundleID,
            processStartToken: "\(processID):1",
            audioObjectID: audioObjectID,
            name: name,
            isLikelyMeetingSource: true,
            owningApplicationBundleID: "com.google.Chrome",
            owningApplicationName: "Google Chrome"
        )
    }
}
