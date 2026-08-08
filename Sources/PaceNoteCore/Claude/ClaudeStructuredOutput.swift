import Foundation

public enum ClaudeStructuredOutputError: Error, Equatable, Sendable {
    case outputTooLarge
    case invalidEnvelope
    case unsuccessfulResult(String)
    case unexpectedTurnCount
    case permissionAttempted
    case missingStructuredOutput
}

public enum ClaudeStructuredOutput {
    private struct Envelope<Output: Decodable>: Decodable {
        let type: String
        let subtype: String
        let isError: Bool
        let numTurns: Int
        let structuredOutput: Output?
        let permissionDenials: [JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case type
            case subtype
            case isError = "is_error"
            case numTurns = "num_turns"
            case structuredOutput = "structured_output"
            case permissionDenials = "permission_denials"
        }
    }

    public static func decode<Output: Decodable & Sendable>(
        _ data: Data,
        as type: Output.Type,
        maximumBytes: Int = 256 * 1_024
    ) throws -> Output {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ClaudeStructuredOutputError.outputTooLarge
        }
        let envelope: Envelope<Output>
        do {
            envelope = try JSONDecoder().decode(Envelope<Output>.self, from: data)
        } catch {
            throw ClaudeStructuredOutputError.invalidEnvelope
        }
        guard envelope.type == "result" else {
            throw ClaudeStructuredOutputError.invalidEnvelope
        }
        guard envelope.subtype == "success", !envelope.isError else {
            throw ClaudeStructuredOutputError.unsuccessfulResult(
                Self.safeSubtype(envelope.subtype)
            )
        }
        guard envelope.numTurns == 1 else {
            throw ClaudeStructuredOutputError.unexpectedTurnCount
        }
        guard envelope.permissionDenials?.isEmpty != false else {
            throw ClaudeStructuredOutputError.permissionAttempted
        }
        guard let output = envelope.structuredOutput else {
            throw ClaudeStructuredOutputError.missingStructuredOutput
        }
        return output
    }

    private static func safeSubtype(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0.value == 95 || $0.value == 45
        }
        return String(String.UnicodeScalarView(allowed)).prefix(80).description
    }
}
