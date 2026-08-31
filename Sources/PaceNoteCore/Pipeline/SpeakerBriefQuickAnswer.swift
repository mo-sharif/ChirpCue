import Foundation

/// Selects a small, directly relevant answer from facts the user wrote about themselves.
///
/// The selector never paraphrases or completes a fact. It can only join up to two already
/// speakable sentences from the local brief, which makes personal Quick answers immediate without
/// asking a model to infer years, employers, projects, roles, or outcomes.
public enum SpeakerBriefQuickAnswer {
    private struct ScoredSentence {
        let index: Int
        let text: String
        let score: Int
    }

    private static let stopWords: Set<String> = [
        "a", "about", "an", "and", "are", "been", "can", "could", "did", "do", "does",
        "first", "for", "from", "had", "has", "have", "how", "i", "is", "it", "kind",
        "many", "me", "my", "of", "on", "or", "question", "tell", "that", "the", "their",
        "them", "this", "to", "ve", "was", "were", "what", "when", "where", "which",
        "who", "why", "with", "would", "you", "your",
    ]

    public static func response(question: String, brief: String?) -> String? {
        guard LocalResponseBridge.requiresPersonalFacts(question),
            let brief = SpeakerBriefPolicy.normalized(brief)
        else {
            return nil
        }

        let questionTerms = terms(in: question)
        let overviewQuestion = isOverviewQuestion(question)
        guard !questionTerms.isEmpty || overviewQuestion else { return nil }

        var ranked: [ScoredSentence] = []
        for (index, sentence) in sentences(in: brief).enumerated() {
            let sentenceWordCount = wordCount(sentence)
            guard sentenceWordCount <= 24 else { continue }
            guard isFirstPersonFact(sentence) else { continue }
            guard GeneralGuidancePolicy.accepts(sentence) else { continue }
            let sentenceTerms = terms(in: sentence)
            let overlapCount = questionTerms.intersection(sentenceTerms).count
            guard overlapCount > 0 || overviewQuestion else { continue }
            ranked.append(
                ScoredSentence(index: index, text: sentence, score: overlapCount)
            )
        }
        ranked.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }

        var selected: [ScoredSentence] = []
        for sentence in ranked {
            let proposed = (selected + [sentence]).sorted { $0.index < $1.index }
                .map(\.text)
                .joined(separator: " ")
            guard wordCount(proposed) <= 24, GeneralGuidancePolicy.accepts(proposed) else {
                continue
            }
            selected.append(sentence)
            if selected.count == 2 { break }
        }

        guard !selected.isEmpty else { return nil }
        return selected.sorted { $0.index < $1.index }.map(\.text).joined(separator: " ")
    }

    private static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var start = text.startIndex

        for index in text.indices where ".!?".contains(text[index]) {
            let next = text.index(after: index)
            guard next == text.endIndex || text[next].isWhitespace else { continue }
            appendSentence(String(text[start...index]), to: &sentences)
            start = next
        }
        if start < text.endIndex {
            appendSentence(String(text[start...]), to: &sentences)
        }
        return sentences
    }

    private static func appendSentence(_ value: String, to sentences: inout [String]) {
        let sentence = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sentence.isEmpty { sentences.append(sentence) }
    }

    private static func terms(in text: String) -> Set<String> {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let raw = folded.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return Set(
            raw.compactMap { token in
                let normalized = normalize(token)
                return stopWords.contains(normalized) ? nil : normalized
            }
        )
    }

    private static func normalize(_ token: String) -> String {
        switch token {
        case "apps", "app", "applications": "application"
        case "builds", "building", "built": "build"
        case "focused", "focusing": "focus"
        case "js": "javascript"
        case "lately", "recently": "recent"
        case "products": "product"
        case "reactjs": "react"
        case "worked", "working", "works": "work"
        case "years": "year"
        default: token
        }
    }

    private static func isOverviewQuestion(_ question: String) -> Bool {
        let normalized = question.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased(with: Locale(identifier: "en_US_POSIX"))
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        return normalized.contains("tell me about yourself")
            || normalized.contains("tell us about yourself")
            || normalized.contains("your background")
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func isFirstPersonFact(_ text: String) -> Bool {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).contains { rawToken in
            let token = rawToken.trimmingCharacters(in: .punctuationCharacters)
            return token == "i"
                || token == "me"
                || token == "my"
                || token.hasPrefix("i'")
                || token.hasPrefix("i’")
        }
    }
}
