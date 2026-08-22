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

    func testCancelledCommittedDeepReservationRefundsAllowance() throws {
        var governor = UsageGovernor(quickPerMinute: 1, deepPerMinute: 1)
        let now = Date(timeIntervalSince1970: 1_000)
        let first = try XCTUnwrap(governor.reserve(.deep, at: now).reservation)
        governor.commit(first)
        governor.finish(first, refundCommitted: true)

        let replacement = governor.reserve(.deep, at: now.addingTimeInterval(1))
        XCTAssertNotNil(replacement.reservation)
    }

    func testUncommittedSupersededReservationsDoNotConsumeRollingLimits() throws {
        var governor = UsageGovernor(quickPerMinute: 1, deepPerMinute: 1)
        let now = Date(timeIntervalSince1970: 1_000)

        let quick = try XCTUnwrap(governor.reserve(.quick, at: now).reservation)
        governor.finish(quick)
        XCTAssertNotNil(governor.reserve(.quick, at: now).reservation)

        let deep = try XCTUnwrap(governor.reserve(.deep, at: now).reservation)
        governor.finish(deep)
        XCTAssertNotNil(governor.reserve(.deep, at: now).reservation)
    }

    func testRollingWindowExpirationDoesNotReleaseActiveDeepExclusivity() throws {
        var governor = UsageGovernor(quickPerMinute: 1, deepPerMinute: 1)
        let now = Date(timeIntervalSince1970: 1_000)
        let active = try XCTUnwrap(governor.reserve(.deep, at: now).reservation)
        governor.commit(active)

        XCTAssertEqual(
            governor.reserve(.deep, at: now.addingTimeInterval(61)),
            .deepAlreadyActive
        )

        governor.finish(active)
        XCTAssertNotNil(
            governor.reserve(.deep, at: now.addingTimeInterval(61)).reservation
        )
    }
}

private extension GovernorReservationDecision {
    var reservation: GovernorReservation? {
        guard case .reserved(let reservation) = self else { return nil }
        return reservation
    }
}
