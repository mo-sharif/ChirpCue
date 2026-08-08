import CryptoKit
import Foundation

public struct ClaudeSubscriptionStatus: Equatable, Sendable {
    public let planType: String
    public let redactedLabel: String
    public let identityHash: String

    public init(planType: String, redactedLabel: String, identityHash: String) {
        self.planType = planType
        self.redactedLabel = redactedLabel
        self.identityHash = identityHash
    }
}

public enum ClaudeSubscriptionError: Error, Equatable, LocalizedError, Sendable {
    case signedOut
    case unsupportedAuthentication
    case unsupportedSubscription
    case missingIdentity
    case invalidStatus
    case runtimeUnavailable

    public var errorDescription: String? {
        switch self {
        case .signedOut:
            "Sign in to Claude Code with a Claude subscription."
        case .unsupportedAuthentication:
            "PrismCue requires first-party Claude.ai subscription authentication."
        case .unsupportedSubscription:
            "PrismCue's personal Claude path supports only first-party Pro or Max subscriptions."
        case .missingIdentity:
            "The signed-in Claude account did not provide a verifiable identity."
        case .invalidStatus:
            "Claude Code returned an invalid authentication status."
        case .runtimeUnavailable:
            "The local Claude Code authentication check is unavailable."
        }
    }
}

public protocol ClaudeSubscriptionChecking: Sendable {
    func subscriptionStatus() async throws -> ClaudeSubscriptionStatus
}

public enum ClaudeAuthStatusParser {
    private struct WireStatus: Decodable {
        let loggedIn: Bool
        let authMethod: String?
        let apiProvider: String?
        let email: String?
        let subscriptionType: String?
    }

    private static let supportedSubscriptions: Set<String> = [
        "pro", "max",
    ]

    public static func parse(_ data: Data) throws -> ClaudeSubscriptionStatus {
        guard !data.isEmpty, data.count <= 32 * 1_024 else {
            throw ClaudeSubscriptionError.invalidStatus
        }
        let wire: WireStatus
        do {
            wire = try JSONDecoder().decode(WireStatus.self, from: data)
        } catch {
            throw ClaudeSubscriptionError.invalidStatus
        }
        guard wire.loggedIn else { throw ClaudeSubscriptionError.signedOut }
        guard wire.authMethod == "claude.ai", wire.apiProvider == "firstParty" else {
            throw ClaudeSubscriptionError.unsupportedAuthentication
        }
        guard let rawPlan = wire.subscriptionType else {
            throw ClaudeSubscriptionError.unsupportedSubscription
        }
        let plan = rawPlan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard supportedSubscriptions.contains(plan) else {
            throw ClaudeSubscriptionError.unsupportedSubscription
        }
        guard let email = normalizedEmail(wire.email) else {
            throw ClaudeSubscriptionError.missingIdentity
        }
        return ClaudeSubscriptionStatus(
            planType: plan,
            redactedLabel: redactedEmail(email),
            identityHash: identityHash(email)
        )
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
            !parts[0].isEmpty,
            !parts[1].isEmpty,
            email.utf8.count <= 320,
            email.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            return nil
        }
        return email
    }

    private static func redactedEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, let first = parts[0].first else {
            return "Claude account"
        }
        return "\(first)…@\(parts[1])"
    }

    private static func identityHash(_ email: String) -> String {
        SHA256.hash(data: Data("claude-email:\(email)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public actor ClaudeCLIAuthStatusChecker: ClaudeSubscriptionChecking {
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

    public func subscriptionStatus() async throws -> ClaudeSubscriptionStatus {
        let result: ClaudeCommandResult
        do {
            result = try await runner.run(
                ClaudeCommandRequest(
                    executableURL: executableURL,
                    currentDirectoryURL: currentDirectoryURL,
                    arguments: ["auth", "status", "--json"],
                    environment: environment,
                    limits: ClaudeCommandLimits(
                        timeout: .seconds(5),
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
            throw ClaudeSubscriptionError.runtimeUnavailable
        }
        guard result.terminationStatus == 0 else {
            throw ClaudeSubscriptionError.signedOut
        }
        var statusBytes = result.standardOutput
        defer {
            statusBytes.resetBytes(in: statusBytes.startIndex..<statusBytes.endIndex)
            statusBytes.removeAll(keepingCapacity: false)
        }
        return try ClaudeAuthStatusParser.parse(statusBytes)
    }
}
