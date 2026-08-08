import Foundation
import XCTest

@testable import PaceNoteCore

final class UsageGovernorTests: XCTestCase {
    func testQuickAndReconciliationShareBudget() {
        var governor = UsageGovernor(quickPerMinute: 2, deepPerMinute: 2)
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(governor.begin(.quick, at: now), .admitted)
        XCTAssertEqual(governor.begin(.reconciliation, at: now), .admitted)
        XCTAssertEqual(governor.begin(.quick, at: now), .quickRateLimited)
        XCTAssertEqual(governor.begin(.quick, at: now.addingTimeInterval(61)), .admitted)
    }

    func testOnlyOneDeepCanRunAtOnce() {
        var governor = UsageGovernor(quickPerMinute: 8, deepPerMinute: 2)
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(governor.begin(.deep, at: now), .admitted)
        XCTAssertEqual(governor.begin(.deep, at: now), .deepAlreadyActive)
        governor.endDeep()
        XCTAssertEqual(governor.begin(.deep, at: now), .admitted)
        governor.endDeep()
        XCTAssertEqual(governor.begin(.deep, at: now), .deepRateLimited)
    }

    func testPersonalDefaultAllowsSixSequentialDeepStartsPerMinute() {
        var governor = UsageGovernor()
        let now = Date(timeIntervalSince1970: 1_000)

        for second in 0..<6 {
            XCTAssertEqual(
                governor.begin(.deep, at: now.addingTimeInterval(TimeInterval(second))),
                .admitted
            )
            governor.endDeep()
        }
        XCTAssertEqual(
            governor.begin(.deep, at: now.addingTimeInterval(6)),
            .deepRateLimited
        )
        XCTAssertEqual(
            governor.begin(.deep, at: now.addingTimeInterval(61)),
            .admitted
        )
    }
}
