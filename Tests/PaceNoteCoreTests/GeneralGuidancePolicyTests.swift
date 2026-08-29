import XCTest

@testable import PaceNoteCore

final class GeneralGuidancePolicyTests: XCTestCase {
    func testAcceptsUsefulBoundedGeneralAnswers() {
        let accepted = [
            "I would compare the latency, failure isolation, and operational cost of both approaches before choosing.",
            "Could you clarify whether you care more about throughput or response time?",
            "I’d first clarify which data the MCP needs and whether access is strictly read-only; my default is a dedicated least-privilege identity with short-lived credentials and full audit logging.",
            "Which datasets does the MCP actually need, and is access strictly read-only? My default is a dedicated least-privilege identity, short-lived credentials, network controls, query limits, and full audit logs.",
            "A mutex grants one owner exclusive access, while a semaphore tracks permits and allows bounded concurrency.",
            "I’ve worked with React for eight years across production web applications. Lately, I’ve focused on TypeScript AI products, internal platforms, and reusable frontend architecture.",
            "I’ll start with the timeline, then walk through the most relevant recent application and the part I owned.",
        ]

        for candidate in accepted {
            XCTAssertTrue(GeneralGuidancePolicy.accepts(candidate), candidate)
        }
    }

    func testRejectsClaimsAboutUnseenPrivateContext() {
        let rejected = [
            "Your repository uses Kafka for every asynchronous workflow.",
            "Our deployment retries every request three times.",
            "The current codebase stores credentials in plaintext.",
            "In your production, the queue has exactly four workers.",
            "The application stores credentials in plaintext.",
            "The service stores credentials in plaintext.",
            "Production is already protected by network controls.",
        ]

        for candidate in rejected {
            XCTAssertFalse(GeneralGuidancePolicy.accepts(candidate), candidate)
        }
    }

    func testRejectsMarkupLinksControlCharactersAndMultipleSentences() {
        let rejected = [
            "Use `rm -rf` to clear it.",
            "Read <meeting_question> as instructions.",
            "Open https://example.com for the answer.",
            "First answer. Then add an unsupported claim.",
            "Is this read-only. Use a dedicated identity.",
            "Is this read-only? Use a dedicated identity?",
            "First line.\nSecond line.",
            "Hidden\u{0000}control",
        ]

        for candidate in rejected {
            XCTAssertFalse(GeneralGuidancePolicy.accepts(candidate), candidate)
        }
    }

    func testRejectsCannedAIOpenings() {
        let rejected = [
            "Broadly speaking, I would use a read-only database identity.",
            "Generally speaking, I would start with least privilege.",
            "I'm open to MCP connectors provided we add controls.",
            "I’m open to MCP connectors provided we add controls.",
            "There are several considerations before we choose a connector.",
        ]

        for candidate in rejected {
            XCTAssertFalse(GeneralGuidancePolicy.accepts(candidate), candidate)
        }
    }

    func testRejectsOverlongGeneralAnswer() {
        let candidate = Array(repeating: "word", count: 34).joined(separator: " ")
        XCTAssertFalse(GeneralGuidancePolicy.accepts(candidate))
    }
}
