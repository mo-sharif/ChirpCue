import Foundation

public enum CodexResponseComplexity: Sendable {
    case quick
    case narrowTechnical
    case hardTechnical
}

public struct CodexModelRoute: Equatable, Sendable {
    public let model: String
    public let effort: String
    public let serviceTier: String?

    public init(model: String, effort: String, serviceTier: String? = nil) {
        self.model = model
        self.effort = effort
        self.serviceTier = serviceTier
    }
}

public struct CodexRoutingPolicy: Equatable, Sendable {
    public let quickModels: [String]
    public let narrowTechnicalModels: [String]
    public let hardTechnicalModels: [String]
    public let deepEffortOverrides: [String: String]
    public let quickEffort: String

    public init(
        quickModels: [String],
        narrowTechnicalModels: [String],
        hardTechnicalModels: [String],
        deepEffortOverrides: [String: String] = [:],
        quickEffort: String = "low"
    ) {
        self.quickModels = quickModels
        self.narrowTechnicalModels = narrowTechnicalModels
        self.hardTechnicalModels = hardTechnicalModels
        self.deepEffortOverrides = deepEffortOverrides
        self.quickEffort = quickEffort
    }

    public static let codex_0_147 = CodexRoutingPolicy(
        quickModels: ["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.3-codex-spark", "gpt-5.4-mini"],
        narrowTechnicalModels: ["gpt-5.6-sol", "gpt-5.6-terra"],
        hardTechnicalModels: ["gpt-5.6-sol", "gpt-5.6-terra"]
    )

    /// Prefer the low-latency Spark lane, with Sol fallback, and Astra Medium for Deep.
    /// The advertised model list and reasoning capabilities decide whether Astra is eligible.
    public static let liveCoaching = CodexRoutingPolicy(
        quickModels: ["gpt-5.3-codex-spark", "gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.4-mini"],
        narrowTechnicalModels: ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"],
        hardTechnicalModels: ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"],
        deepEffortOverrides: ["gpt-6-astra": "medium"],
        quickEffort: "none"
    )
}

public enum CodexModelRoutingError: Error, Equatable, Sendable {
    case noEligibleModel(CodexResponseComplexity)
}

public struct CodexModelRouter: Sendable {
    private let models: [CodexModel]
    private let policy: CodexRoutingPolicy

    public init(models: [CodexModel], policy: CodexRoutingPolicy) {
        self.models = models.filter { $0.hidden != true }
        self.policy = policy
    }

    public func route(for complexity: CodexResponseComplexity) throws -> CodexModelRoute {
        let preferred: [String]
        let desiredEffort: String
        switch complexity {
        case .quick:
            preferred = policy.quickModels
            desiredEffort = policy.quickEffort
        case .narrowTechnical:
            preferred = policy.narrowTechnicalModels
            desiredEffort = "medium"
        case .hardTechnical:
            preferred = policy.hardTechnicalModels
            desiredEffort = "high"
        }

        for identifier in preferred {
            guard let model = models.first(where: { $0.id == identifier || $0.model == identifier }) else { continue }
            let efforts = model.supportedReasoningEfforts.map(\.reasoningEffort)
            let serviceTier = complexity == .quick ? Self.fastestServiceTier(for: model) : nil
            if complexity != .quick, let effort = policy.deepEffortOverrides[identifier] {
                // Do not silently substitute a slower reasoning mode when this live-coaching
                // route cannot be honored. Continue to the next supported fallback instead.
                guard efforts.contains(effort) else { continue }
                return CodexModelRoute(model: model.model, effort: effort, serviceTier: serviceTier)
            }
            if efforts.contains(desiredEffort) {
                return CodexModelRoute(
                    model: model.model,
                    effort: desiredEffort,
                    serviceTier: serviceTier
                )
            }
            if let fallback = Self.closestEffort(to: desiredEffort, from: efforts) {
                return CodexModelRoute(
                    model: model.model,
                    effort: fallback,
                    serviceTier: serviceTier
                )
            }
        }
        throw CodexModelRoutingError.noEligibleModel(complexity)
    }

    private static func closestEffort(to desired: String, from supported: [String]) -> String? {
        let ranking = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        guard let desiredIndex = ranking.firstIndex(of: desired) else { return supported.first }
        return supported.min { lhs, rhs in
            abs((ranking.firstIndex(of: lhs) ?? desiredIndex) - desiredIndex)
                < abs((ranking.firstIndex(of: rhs) ?? desiredIndex) - desiredIndex)
        }
    }

    private static func fastestServiceTier(for model: CodexModel) -> String? {
        let advertised = Set((model.serviceTiers ?? []).map { $0.id.lowercased() })
        return ["ultrafast", "priority", "fast"].first(where: advertised.contains)
    }
}
