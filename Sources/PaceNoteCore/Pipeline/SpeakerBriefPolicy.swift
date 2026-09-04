import Foundation

/// Bounds the optional facts a user supplies about their own background.
/// The brief is context, never model instruction. Quick receives a smaller prefix than Deep.
public enum SpeakerBriefPolicy {
    public static let maximumCharacters = 8_000
    public static let quickMaximumCharacters = 1_500

    public static func quickContext(_ value: String?) -> String? {
        normalized(value).map { String($0.prefix(quickMaximumCharacters)) }
    }

    public static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }

        let withoutNulls = value.replacingOccurrences(of: "\0", with: "")
        let flattened =
            withoutNulls
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !flattened.isEmpty else { return nil }
        return String(flattened.prefix(maximumCharacters))
    }
}
