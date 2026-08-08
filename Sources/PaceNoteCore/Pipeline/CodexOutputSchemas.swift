import Foundation

public enum CodexOutputSchema {
    public static let quick: JSONValue = [
        "type": "object",
        "additionalProperties": false,
        "required": ["turnID", "generation", "sayNow", "needsDeep", "confidence", "reason"],
        "properties": [
            "turnID": ["type": "string", "format": "uuid"],
            "generation": ["type": "integer", "minimum": 0],
            "sayNow": ["type": "string", "minLength": 1, "maxLength": 220],
            "needsDeep": ["type": "boolean"],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
            "reason": ["type": "string", "minLength": 1, "maxLength": 120],
        ],
    ]

    public static let deep: JSONValue = [
        "type": "object",
        "additionalProperties": false,
        "required": [
            "turnID", "generation", "groundingFingerprint", "kind", "candidateSayNext", "confidence", "basis",
            "missingEvidence",
        ],
        "properties": [
            "turnID": ["type": "string", "format": "uuid"],
            "generation": ["type": "integer", "minimum": 0],
            "groundingFingerprint": ["type": ["string", "null"]],
            "kind": ["type": "string", "enum": ["answer", "clarification", "abstention"]],
            "candidateSayNext": ["type": "string", "minLength": 1, "maxLength": 320],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
            "basis": [
                "type": "array",
                "maxItems": 6,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["repoAlias", "relativePath", "startLine", "endLine", "fileHash", "claim"],
                    "properties": [
                        "repoAlias": ["type": "string"],
                        "relativePath": ["type": "string"],
                        "startLine": ["type": "integer", "minimum": 1],
                        "endLine": ["type": "integer", "minimum": 1],
                        "fileHash": ["type": "string"],
                        "claim": ["type": "string"],
                    ],
                ],
            ],
            "missingEvidence": [
                "type": "array",
                "maxItems": 4,
                "items": ["type": "string"],
            ],
        ],
    ]

    public static let reconciliation: JSONValue = [
        "type": "object",
        "additionalProperties": false,
        "required": ["relationship", "transition"],
        "properties": [
            "relationship": [
                "type": "string",
                "enum": ["continue", "correct", "clarify", "abstain"],
            ],
            "transition": ["type": "string", "maxLength": 100],
        ],
    ]
}

public enum CodexStructuredOutputError: Error, Equatable, Sendable {
    case noFinalMessage
    case turnDidNotComplete(String)
    case invalidUTF8
    case invalidJSON
    case realtimeClosedWithoutAnswer
}

public enum CodexStructuredOutput {
    public static func collect<T: Decodable & Sendable>(
        from session: CodexTurnSession,
        as type: T.Type
    ) async throws -> T {
        var finalText: String?
        var terminalStatus: String?

        for try await event in session.events {
            switch event {
            case .itemCompleted(let item):
                guard item["type"]?.stringValue == "agentMessage",
                    let text = item["text"]?.stringValue
                else { continue }
                let phase = item["phase"]?.stringValue
                if phase == nil || phase == "final_answer" { finalText = text }
            case .completed(let status):
                terminalStatus = status
            case .agentMessageDelta, .notification:
                break
            }
        }

        guard terminalStatus == "completed" else {
            throw CodexStructuredOutputError.turnDidNotComplete(terminalStatus ?? "missing")
        }
        guard let finalText else { throw CodexStructuredOutputError.noFinalMessage }
        return try decode(finalText, as: type)
    }

    public static func firstRealtimeAnswer(from session: CodexRealtimeSession) async throws -> String {
        for try await event in session.events {
            switch event {
            case .transcriptDone(let role, let text) where Self.isAssistantRole(role):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .itemAdded(let item):
                if let text = extractText(from: item), !text.isEmpty { return text }
            case .closed:
                throw CodexStructuredOutputError.realtimeClosedWithoutAnswer
            case .started, .transcriptDelta, .transcriptDone:
                continue
            }
        }
        throw CodexStructuredOutputError.realtimeClosedWithoutAnswer
    }

    public static func decode<T: Decodable & Sendable>(_ text: String, as type: T.Type) throws -> T {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            throw CodexStructuredOutputError.invalidUTF8
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CodexStructuredOutputError.invalidJSON
        }
    }

    private static func isAssistantRole(_ role: String) -> Bool {
        role == "assistant" || role == "model"
    }

    private static func extractText(from item: JSONValue) -> String? {
        if let direct = item["text"]?.stringValue {
            return direct.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let content = item["content"]?.arrayValue else { return nil }
        return content.compactMap { value in
            value["text"]?.stringValue ?? value["transcript"]?.stringValue
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
