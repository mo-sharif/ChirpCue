import XCTest

@testable import PaceNoteCore

final class LocalResponseBridgeTests: XCTestCase {
    func testSecurityQuestionGetsAnImmediateSpecificOpener() {
        let response = LocalResponseBridge.response(
            for: "How do we keep the database secure when our MCP accesses it?"
        )

        XCTAssertTrue(response.contains("least-privilege"))
        XCTAssertTrue(response.contains("read-only"))
        XCTAssertTrue(response.contains("audit logs"))
        XCTAssertTrue(GeneralGuidancePolicy.accepts(response))
        XCTAssertLessThanOrEqual(response.split(whereSeparator: \Character.isWhitespace).count, 24)
    }

    func testEveryBridgeCategoryStaysSpeakableAndPolicySafe() {
        let questions = [
            "Why is this service failing?",
            "How would this scale under load?",
            "How do you compare these tradeoffs?",
            "How would you resolve conflict on the team?",
            "Tell me about a time you made a mistake.",
            "How would you design an asynchronous API?",
            "What is eventual consistency?",
            "How should we approach this?",
        ]

        for question in questions {
            let response = LocalResponseBridge.response(for: question)
            XCTAssertTrue(GeneralGuidancePolicy.accepts(response), response)
            XCTAssertLessThanOrEqual(
                response.split(whereSeparator: \Character.isWhitespace).count,
                24,
                response
            )
        }
    }

    func testPersonalExperienceQuestionGetsAnOrderedNoninventedBridge() {
        let question =
            "My first question is, how many years have you had with React JS, and what kind of applications have you been working on lately?"

        let response = LocalResponseBridge.response(for: question)

        XCTAssertTrue(LocalResponseBridge.requiresPersonalFacts(question))
        XCTAssertEqual(
            response,
            "I’ll start with the timeline, then walk through the most relevant recent application and the part I owned."
        )
        XCTAssertFalse(response.lowercased().contains("which part"))
        XCTAssertTrue(GeneralGuidancePolicy.accepts(response))
        XCTAssertLessThanOrEqual(response.split(whereSeparator: \Character.isWhitespace).count, 24)
    }

    func testCustomConfiguredBridgeRemainsUnchanged() {
        let custom = "I’d clarify the riskiest constraint first."
        let configuration = ResponseCoordinatorConfiguration(bridgeText: custom)

        XCTAssertEqual(configuration.bridgeText(for: "How should this scale?"), custom)
    }

    func testCommonPersonalInterviewPromptsUseNaturalNoninventedOpeners() {
        let expected: [(String, String)] = [
            (
                "Tell me about a time you influenced without authority.",
                "I’ll anchor this in one concrete example, then make the decision, my role, and the outcome clear."
            ),
            (
                "What is your greatest strength?",
                "I’ll give the honest headline first, then ground it in one recent example and what changed because of it."
            ),
            (
                "Why are you interested in this role?",
                "I’ll connect what I’m looking for next to this role, then make the fit concrete with one recent example."
            ),
        ]

        for (question, opener) in expected {
            XCTAssertTrue(LocalResponseBridge.requiresPersonalFacts(question), question)
            XCTAssertEqual(LocalResponseBridge.response(for: question), opener)
            XCTAssertTrue(GeneralGuidancePolicy.accepts(opener), opener)
            XCTAssertFalse(opener.contains("?"), opener)
        }
    }
}
