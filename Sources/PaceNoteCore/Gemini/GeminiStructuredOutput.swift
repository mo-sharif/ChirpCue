import Foundation

public enum GeminiStructuredOutputError: Error, Equatable, Sendable {
    case outputTooLarge
    case invalidEnvelope
    case unsuccessfulResult
    case unexpectedTurnCount
    case missingStructuredOutput
}

public enum GeminiStructuredOutput {
    private struct Envelope<Output: Decodable>: Decodable {
        let status: String
        let response: ResponseValue<Output>?
        let error: String?
        let numTurns: Int?

        private enum CodingKeys: String, CodingKey {
            case status
            case response
            case error
            case numTurns = "num_turns"
        }
    }

    private enum ResponseValue<Output: Decodable>: Decodable {
        case text(String)
        case object(Output)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .object(try container.decode(Output.self))
            }
        }
    }

    public static func decode<Output: Decodable & Sendable>(
        _ data: Data,
        as type: Output.Type,
        maximumBytes: Int = 256 * 1_024
    ) throws -> Output {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw GeminiStructuredOutputError.outputTooLarge
        }
        let envelope: Envelope<Output>
        do {
            envelope = try JSONDecoder().decode(Envelope<Output>.self, from: data)
        } catch {
            throw GeminiStructuredOutputError.invalidEnvelope
        }
        guard envelope.status.lowercased() == "success",
            envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        else {
            throw GeminiStructuredOutputError.unsuccessfulResult
        }
        if let count = envelope.numTurns, !(1...4).contains(count) {
            throw GeminiStructuredOutputError.unexpectedTurnCount
        }
        guard let response = envelope.response else {
            throw GeminiStructuredOutputError.missingStructuredOutput
        }
        switch response {
        case .object(let output):
            return output
        case .text(let text):
            guard let bytes = text.data(using: .utf8), bytes.count <= maximumBytes else {
                throw GeminiStructuredOutputError.outputTooLarge
            }
            do {
                return try JSONDecoder().decode(Output.self, from: bytes)
            } catch {
                throw GeminiStructuredOutputError.invalidEnvelope
            }
        }
    }
}
