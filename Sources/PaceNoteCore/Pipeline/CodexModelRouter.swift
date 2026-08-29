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

    public init(
        quickModels: [String],
        narrowTechnicalModels: [String],
        hardTechnicalModels: [String]
    ) {
        self.quickModels = quickModels
        self.narrowTechnicalModels = narrowTechnicalModels
        self.hardTechnicalModels = hardTechnicalModels
    }

    public static let codex_0_147 = CodexRoutingPolicy(
        quickModels: ["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.3-codex-spark", "gpt-5.4-mini"],
        narrowTechnicalModels: ["gpt-5.6-terra", "gpt-5.6-sol"],
        hardTechnicalModels: ["gpt-5.6-sol", "gpt-5.6-terra"]
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
            desiredEffort = "low"
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
