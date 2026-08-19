import Foundation

public struct GeminiSubscriptionStatus: Equatable, Sendable {
    public let planType: String
    public let redactedLabel: String
    public let modelIDs: [String]

    public init(planType: String, redactedLabel: String, modelIDs: [String]) {
        self.planType = planType
        self.redactedLabel = redactedLabel
        self.modelIDs = modelIDs
    }
}

public enum GeminiSubscriptionError: Error, Equatable, LocalizedError, Sendable {
    case signedOut
    case noSupportedModels
    case invalidStatus
    case runtimeUnavailable

    public var errorDescription: String? {
        switch self {
        case .signedOut:
            "Sign in to the official Google Antigravity CLI with your Google account."
        case .noSupportedModels:
            "The signed-in Google account does not currently expose a supported Gemini model."
        case .invalidStatus:
            "Google Antigravity returned an invalid model-access status."
        case .runtimeUnavailable:
            "The local Google Antigravity subscription check is unavailable."
        }
    }
}

public protocol GeminiSubscriptionChecking: Sendable {
    func subscriptionStatus() async throws -> GeminiSubscriptionStatus
}

public enum GeminiModelListParser {
    public static func parse(_ data: Data) throws -> GeminiSubscriptionStatus {
        guard !data.isEmpty, data.count <= 32 * 1_024,
            let text = String(data: data, encoding: .utf8)
        else {
            throw GeminiSubscriptionError.invalidStatus
        }
        let safe = text.lowercased()
        if safe.contains("please sign in") || safe.contains("not signed in") {
            throw GeminiSubscriptionError.signedOut
        }
        let separators = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._")
        ).inverted
        let models = Set(
            text.components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { token in
                    token.utf8.count <= 128
                        && token.hasPrefix("gemini-")
                        && token.unicodeScalars.allSatisfy {
                            CharacterSet.alphanumerics.contains($0)
                                || "-._".unicodeScalars.contains($0)
                        }
                }
        ).sorted()
        guard !models.isEmpty else { throw GeminiSubscriptionError.noSupportedModels }
        return GeminiSubscriptionStatus(
            planType: "Google AI",
            redactedLabel: "Google account",
            modelIDs: models
        )
    }
}

public actor GeminiCLIAuthStatusChecker: GeminiSubscriptionChecking {
    private let executableURL: URL
    private let currentDirectoryURL: URL
    private let environment: [String: String]
    private let runner: any ClaudeCommandRunning

    public init(
        executableURL: URL,
        currentDirectoryURL: URL,
        environment: [String: String],
        runner: any ClaudeCommandRunning = ClaudeProcessRunner()
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.currentDirectoryURL = currentDirectoryURL.standardizedFileURL
        self.environment = environment
        self.runner = runner
    }

    public func subscriptionStatus() async throws -> GeminiSubscriptionStatus {
        let result: ClaudeCommandResult
        do {
            result = try await runner.run(
                ClaudeCommandRequest(
                    executableURL: executableURL,
                    currentDirectoryURL: currentDirectoryURL,
                    arguments: ["models"],
                    environment: environment,
                    limits: ClaudeCommandLimits(
                        timeout: .seconds(10),
                        maximumStandardInputBytes: 0,
                        maximumStandardOutputBytes: 32 * 1_024,
                        maximumStandardErrorBytes: 8 * 1_024,
                        terminationGracePeriod: .milliseconds(500)
                    )
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GeminiSubscriptionError.runtimeUnavailable
        }
        var output = result.standardOutput
        var errors = result.standardError
        defer {
            output.resetBytes(in: output.startIndex..<output.endIndex)
            output.removeAll(keepingCapacity: false)
            errors.resetBytes(in: errors.startIndex..<errors.endIndex)
            errors.removeAll(keepingCapacity: false)
        }
        if result.terminationStatus != 0 {
            let combined = output + errors
            if let text = String(data: combined, encoding: .utf8)?.lowercased(),
                text.contains("sign in")
            {
                throw GeminiSubscriptionError.signedOut
            }
            throw GeminiSubscriptionError.runtimeUnavailable
        }
        return try GeminiModelListParser.parse(output)
    }
}
