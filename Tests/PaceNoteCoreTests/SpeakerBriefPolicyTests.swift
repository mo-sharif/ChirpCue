import XCTest

@testable import PaceNoteCore

final class SpeakerBriefPolicyTests: XCTestCase {
    func testNormalizesAndBoundsUserSuppliedFacts() throws {
        let source = "  Eight years with React.\n\nLately building TypeScript AI products.  "

        XCTAssertEqual(
            SpeakerBriefPolicy.normalized(source),
            "Eight years with React. Lately building TypeScript AI products."
        )

        let long = String(repeating: "x", count: SpeakerBriefPolicy.maximumCharacters + 20)
        let bounded = try XCTUnwrap(SpeakerBriefPolicy.normalized(long))
        XCTAssertEqual(bounded.count, SpeakerBriefPolicy.maximumCharacters)
    }

    func testEmptyBriefBecomesAbsent() {
        XCTAssertNil(SpeakerBriefPolicy.normalized(nil))
        XCTAssertNil(SpeakerBriefPolicy.normalized(" \n\t "))
    }
}
