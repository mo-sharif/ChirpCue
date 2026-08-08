import XCTest

@testable import PaceNoteCore

final class GeneralGuidancePolicyTests: XCTestCase {
    func testAcceptsEverySupportedFrameAndQualifier() throws {
        let action = try XCTUnwrap(GeneralGuidancePolicy.approvedActionClauses.first)

        for frame in GeneralGuidancePolicy.approvedFrames {
            let candidate = "\(frame)\(action)."
            XCTAssertTrue(GeneralGuidancePolicy.accepts(candidate), candidate)
        }
        for qualifier in GeneralGuidancePolicy.approvedQualifiers {
            let candidate = "\(qualifier)\(GeneralGuidancePolicy.approvedFrames[0])\(action)."
            XCTAssertTrue(GeneralGuidancePolicy.accepts(candidate), candidate)
        }
    }

    func testAcceptsEveryApprovedActionOnlyAsAWholeProduction() {
        for action in GeneralGuidancePolicy.approvedActionClauses {
            let candidate = "I would \(action)."
            XCTAssertTrue(GeneralGuidancePolicy.accepts(candidate), candidate)
            XCTAssertFalse(GeneralGuidancePolicy.accepts("I would \(action) plus more."), action)
        }
    }

    func testRejectsReportedLowercaseOrganizationAndSecondaryClauseBypasses() {
        let rejected = [
            "I would validate latency as acme leaks patient records.",
            "I would add monitoring after acme leaked patient records.",
            "I would validate latency or acme leaks patient records.",
            "I would compare latency between queues and acme leaks patient records.",
            "We should assess acme leaked patient records.",
            "I would treat acme compromised accounts as resolved.",
            "We should document our-system-leaks-patient-records.",
            "We can use patient records without consent.",
        ]

        for candidate in rejected {
            XCTAssertFalse(GeneralGuidancePolicy.accepts(candidate), candidate)
        }
    }

    func testRejectsConnectorSynonymsPossessivesAndCapabilityClaims() {
        let rejected = [
            "I would add monitoring given acme leaked patient records.",
            "I would add monitoring despite acme leaking patient records.",
            "I would validate latency before acme leaks patient records.",
            "I would validate latency plus acme leaks patient records.",
            "I would confirm acme-stores-patient-records-without-encryption.",
            "I would review acme stolen credentials.",
            "One option is to use acme queue for patient data.",
            "We could use patient records without consent.",
            "We might use patient records without consent.",
            "I'd validate the storage design before launch.",
            "I’d validate the storage design before launch.",
            "I would recommend Acme's queue for this workload.",
            "I would recommend Acme’s queue for this workload.",
            "I would validate latency. acme leaks patient records.",
            "I would validate latency, but acme leaks patient records.",
            "I would validate latency; acme leaks patient records.",
            "I would validate latency: acme leaks patient records.",
        ]

        for candidate in rejected {
            XCTAssertFalse(GeneralGuidancePolicy.accepts(candidate), candidate)
        }
    }

    func testRejectsPlausibleButUnapprovedAdvisoryProse() {
        let rejected = [
            "I would compare kafka and rabbitmq before choosing.",
            "I would validate the storage design before launch.",
            "We should confirm the database configuration.",
            "A practical approach is to inspect the current deployment.",
            "One option is to use the existing service.",
            "Broadly speaking, a queue separates acceptance latency from downstream processing.",
            "There are two broad options to compare before committing to an implementation.",
        ]

        for candidate in rejected {
            XCTAssertFalse(GeneralGuidancePolicy.accepts(candidate), candidate)
        }
    }
}
