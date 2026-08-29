import Foundation

public enum GovernedOperation: Equatable, Sendable {
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

public struct GovernorReservation: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let operation: GovernedOperation
}

public enum GovernorReservationDecision: Equatable, Sendable {
    case reserved(GovernorReservation)
    case quickRateLimited
    case deepRateLimited
    case deepAlreadyActive
}

public struct UsageGovernor: Sendable {
    private struct Start: Sendable {
        let reservation: GovernorReservation
        let date: Date
        var committed: Bool
    }

    public let quickPerMinute: Int
    public let deepPerMinute: Int
    public let maximumConcurrentDeep: Int
    private var quickStarts: [Start] = []
    private var deepStarts: [Start] = []
    private var activeDeepReservationIDs: Set<UUID> = []

    public init(
        quickPerMinute: Int = 8,
        deepPerMinute: Int = 6,
        maximumConcurrentDeep: Int = 2
    ) {
        self.quickPerMinute = quickPerMinute
        self.deepPerMinute = deepPerMinute
        self.maximumConcurrentDeep = max(1, maximumConcurrentDeep)
    }

    public mutating func begin(_ operation: GovernedOperation, at date: Date = Date()) -> GovernorDecision {
        switch reserve(operation, at: date) {
        case .reserved(let reservation):
            commit(reservation)
            return .admitted
        case .quickRateLimited:
            return .quickRateLimited
        case .deepRateLimited:
            return .deepRateLimited
        case .deepAlreadyActive:
            return .deepAlreadyActive
        }
    }

    public mutating func reserve(
        _ operation: GovernedOperation,
        at date: Date = Date()
    ) -> GovernorReservationDecision {
        prune(at: date)
        let reservation = GovernorReservation(id: UUID(), operation: operation)
        switch operation {
        case .quick, .reconciliation:
            guard quickStarts.count < quickPerMinute else { return .quickRateLimited }
            quickStarts.append(Start(reservation: reservation, date: date, committed: false))
            return .reserved(reservation)
        case .deep:
            guard activeDeepReservationIDs.count < maximumConcurrentDeep else {
                return .deepAlreadyActive
            }
            guard deepStarts.count < deepPerMinute else { return .deepRateLimited }
            deepStarts.append(Start(reservation: reservation, date: date, committed: false))
            activeDeepReservationIDs.insert(reservation.id)
            return .reserved(reservation)
        }
    }

    public mutating func commit(_ reservation: GovernorReservation) {
        switch reservation.operation {
        case .quick, .reconciliation:
            guard
                let index = quickStarts.firstIndex(where: {
                    $0.reservation.id == reservation.id
                })
            else {
                return
            }
            quickStarts[index].committed = true
        case .deep:
            guard
                let index = deepStarts.firstIndex(where: {
                    $0.reservation.id == reservation.id
                })
            else {
                return
            }
            deepStarts[index].committed = true
        }
    }

    /// Completes a reservation. Work that never reached the provider is always removed. A
    /// cancelled provider operation is also refundable so superseded turns cannot exhaust the
    /// app's rolling local allowance.
    public mutating func finish(
        _ reservation: GovernorReservation,
        refundCommitted: Bool = false
    ) {
        switch reservation.operation {
        case .quick, .reconciliation:
            guard
                let start = quickStarts.first(where: {
                    $0.reservation.id == reservation.id
                })
            else {
                return
            }
            if !start.committed || refundCommitted {
                quickStarts.removeAll { $0.reservation.id == reservation.id }
            }
        case .deep:
            guard
                let start = deepStarts.first(where: {
                    $0.reservation.id == reservation.id
                })
            else {
                activeDeepReservationIDs.remove(reservation.id)
                return
            }
            if !start.committed || refundCommitted {
                deepStarts.removeAll { $0.reservation.id == reservation.id }
            }
            activeDeepReservationIDs.remove(reservation.id)
        }
    }

    public mutating func endDeep() {
        guard
            let start = deepStarts.first(where: {
                activeDeepReservationIDs.contains($0.reservation.id)
            })
        else {
            activeDeepReservationIDs.removeAll()
            return
        }
        finish(start.reservation)
    }

    private mutating func prune(at date: Date) {
        let cutoff = date.addingTimeInterval(-60)
        quickStarts.removeAll { $0.date <= cutoff }
        deepStarts.removeAll { start in
            start.date <= cutoff && !activeDeepReservationIDs.contains(start.reservation.id)
        }
    }
}
