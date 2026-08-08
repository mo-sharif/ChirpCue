import Foundation

public enum GovernedOperation: Sendable {
    case quick
    case reconciliation
    case deep
}

public enum GovernorDecision: Equatable, Sendable {
    case admitted
    case quickRateLimited
    case deepRateLimited
    case deepAlreadyActive
}

public struct UsageGovernor: Sendable {
    public let quickPerMinute: Int
    public let deepPerMinute: Int
    private var quickStarts: [Date] = []
    private var deepStarts: [Date] = []
    private var deepActive = false

    public init(quickPerMinute: Int = 8, deepPerMinute: Int = 2) {
        self.quickPerMinute = quickPerMinute
        self.deepPerMinute = deepPerMinute
    }

    public mutating func begin(_ operation: GovernedOperation, at date: Date = Date()) -> GovernorDecision {
        prune(at: date)
        switch operation {
        case .quick, .reconciliation:
            guard quickStarts.count < quickPerMinute else { return .quickRateLimited }
            quickStarts.append(date)
            return .admitted
        case .deep:
            guard !deepActive else { return .deepAlreadyActive }
            guard deepStarts.count < deepPerMinute else { return .deepRateLimited }
            deepStarts.append(date)
            deepActive = true
            return .admitted
        }
    }

    public mutating func endDeep() {
        deepActive = false
    }

    private mutating func prune(at date: Date) {
        let cutoff = date.addingTimeInterval(-60)
        quickStarts.removeAll { $0 <= cutoff }
        deepStarts.removeAll { $0 <= cutoff }
    }
}
