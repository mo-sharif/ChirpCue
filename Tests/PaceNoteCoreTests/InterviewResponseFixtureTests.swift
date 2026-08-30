import XCTest

@testable import PaceNoteCore

final class InterviewResponseFixtureTests: XCTestCase {
    private let speakerBrief = """
        I’ve worked with React for eight years across production web applications.
        Lately, I’ve focused on TypeScript AI products and reusable frontend architecture.
        My greatest strength is turning ambiguous product problems into clear engineering plans.
        One project I’m proud of was a React migration that reduced release risk and clarified ownership.
        I influenced a platform migration without formal authority by aligning teams on measurable risks and a reversible rollout.
        I’m looking for a staff role where I can stay hands-on while shaping architecture and product direction.
        """

    func testPersonalInterviewFixturesProduceImmediateRelevantFacts() throws {
        let fixtures: [(question: String, requiredText: String)] = [
            (
                "How many years have you had with React JS, and what applications have you worked on lately?",
                "I’ve worked with React for eight years"
            ),
            (
                "What would you say is your greatest strength?",
                "My greatest strength is turning ambiguous product problems"
            ),
            (
                "Walk me through a recent project you’re proud of.",
                "One project I’m proud of was a React migration"
            ),
            (
                "Describe a time you influenced without authority.",
                "I influenced a platform migration without formal authority"
            ),
            (
                "What are you looking for in your next role?",
                "I’m looking for a staff role"
            ),
        ]

        for fixture in fixtures {
            let answer = try XCTUnwrap(
                SpeakerBriefQuickAnswer.response(
                    question: fixture.question,
                    brief: speakerBrief
                ),
                fixture.question
            )
            XCTAssertTrue(answer.contains(fixture.requiredText), answer)
            XCTAssertLessThanOrEqual(
                answer.split(whereSeparator: \Character.isWhitespace).count,
                24,
                answer
            )
            XCTAssertTrue(GeneralGuidancePolicy.accepts(answer), answer)
        }
    }

    func testSameFixturesWithoutBriefNeverInventPersonalFactsOrAskWhichPart() {
        let questions = [
            "How many years have you had with React JS, and what applications have you worked on lately?",
            "What would you say is your greatest strength?",
            "Walk me through a recent project you’re proud of.",
            "Describe a time you influenced without authority.",
            "What are you looking for in your next role?",
        ]

        for question in questions {
            let answer = LocalResponseBridge.response(for: question)
            XCTAssertFalse(answer.lowercased().contains("which part"), answer)
            XCTAssertFalse(answer.contains("eight years"), answer)
            XCTAssertFalse(answer.contains("React migration"), answer)
            XCTAssertTrue(GeneralGuidancePolicy.accepts(answer), answer)
        }
    }
}
