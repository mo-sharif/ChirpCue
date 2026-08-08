import Foundation

public enum MeetingTimingTargetStatus: Equatable, Sendable {
    case notEvaluated
    case met
    case missed
}

public enum MeetingDeepTimingOutcome: Equatable, Sendable {
    case pending
    case ready
    case unavailable
    case staleDiscarded
}

public enum MeetingTimingInvalidationOutcome: Equatable, Sendable {
    case newerTurn
    case localSpeech
    case userDismissed
    case sessionPaused
    case captureInterrupted
    case sessionStopped
}

public struct MeetingTurnTimingSample: Equatable, Sendable {
    public let sequence: UInt64
    public let turnStableToBridgeReadySeconds: TimeInterval?
    public let confirmedLocalSpeechObserved: Bool
    public let bridgeToConfirmedLocalSpeechMarginSeconds: TimeInterval?
    public let turnStableToVerifiedDeepReadySeconds: TimeInterval?
    public let deepOutcome: MeetingDeepTimingOutcome
    public let invalidationOutcome: MeetingTimingInvalidationOutcome?
    public let userDismissed: Bool
}

public struct MeetingTimingTargetEvaluation: Equatable, Sendable {
    public let bridgeReadyDeadlineSeconds: TimeInterval
    public let bridgeReadySampleCount: Int
    public let bridgeReadyMissingSampleCount: Int
    public let bridgeReadyWorstSeconds: TimeInterval?
    public let bridgeReadyDeadlineStatus: MeetingTimingTargetStatus

    public let bridgeBeforeLocalSpeechTargetRate: Double
    public let bridgeBeforeLocalSpeechSampleCount: Int
    public let bridgeBeforeLocalSpeechObservedRate: Double?
    public let bridgeBeforeLocalSpeechStatus: MeetingTimingTargetStatus

    public let verifiedDeepP50TargetSeconds: TimeInterval
    public let verifiedDeepP95TargetSeconds: TimeInterval
    public let verifiedDeepSampleCount: Int
    public let verifiedDeepObservedP50Seconds: TimeInterval?
    public let verifiedDeepObservedP95Seconds: TimeInterval?
    public let verifiedDeepP50Status: MeetingTimingTargetStatus
    public let verifiedDeepP95Status: MeetingTimingTargetStatus
}

public struct MeetingTimingSnapshot: Equatable, Sendable {
    public let samples: [MeetingTurnTimingSample]
    public let retainedTurnCount: Int
    public let droppedTurnCount: Int
    public let staleDiscardedCount: Int
    public let invalidatedTurnCount: Int
    public let userDismissedCount: Int
    public let targets: MeetingTimingTargetEvaluation

    public static let empty = MeetingTimingSnapshot(
        samples: [],
        retainedTurnCount: 0,
        droppedTurnCount: 0,
        staleDiscardedCount: 0,
        invalidatedTurnCount: 0,
        userDismissedCount: 0,
        targets: TimingLedger.targetEvaluation(for: [], droppedTurnCount: 0)
    )
}

struct TimingLedger: Sendable {
    static let defaultCapacity = 128
    static let maximumCapacity = 1_024

    private struct Entry: Sendable {
        let generation: UInt64
        let sequence: UInt64
        let turnStartedAt: TimeInterval
        var bridgeReadyAt: TimeInterval?
        var confirmedLocalSpeechObserved = false
        var confirmedLocalSpeechAt: TimeInterval?
        var verifiedDeepReadyAt: TimeInterval?
        var deepOutcome: MeetingDeepTimingOutcome = .pending
        var invalidationOutcome: MeetingTimingInvalidationOutcome?
        var userDismissed = false
    }

    private let capacity: Int
    private var entries: [Entry] = []
    private var nextSequence: UInt64 = 1
    private var droppedTurnCount = 0

    init(capacity: Int = defaultCapacity) {
        self.capacity = min(max(1, capacity), Self.maximumCapacity)
    }

    mutating func beginTurn(generation: UInt64, at timestamp: TimeInterval) {
        guard !entries.contains(where: { $0.generation == generation }) else { return }
        let startedAt = sanitized(timestamp)
        entries.append(
            Entry(
                generation: generation,
                sequence: nextSequence,
                turnStartedAt: startedAt
            )
        )
        nextSequence &+= 1
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
            droppedTurnCount += 1
        }
    }

    mutating func recordBridgeReady(generation: UInt64, at timestamp: TimeInterval) {
        guard let index = index(for: generation), entries[index].bridgeReadyAt == nil else {
            return
        }
        entries[index].bridgeReadyAt = sanitized(timestamp)
    }

    mutating func recordConfirmedLocalSpeech(
        generation: UInt64,
        at timestamp: TimeInterval?
    ) {
        guard
            let index = index(for: generation),
            !entries[index].confirmedLocalSpeechObserved
        else {
            return
        }
        entries[index].confirmedLocalSpeechObserved = true
        if let timestamp, timestamp.isFinite, timestamp >= 0 {
            entries[index].confirmedLocalSpeechAt = timestamp
        }
    }

    mutating func recordVerifiedDeepReady(generation: UInt64, at timestamp: TimeInterval) {
        guard
            let index = index(for: generation),
            entries[index].verifiedDeepReadyAt == nil
        else {
            return
        }
        entries[index].verifiedDeepReadyAt = sanitized(timestamp)
        entries[index].deepOutcome = .ready
    }

    mutating func recordDeepUnavailable(generation: UInt64, at timestamp: TimeInterval) {
        guard let index = index(for: generation) else { return }
        _ = sanitized(timestamp)
        guard entries[index].deepOutcome == .pending else { return }
        entries[index].deepOutcome = .unavailable
    }

    mutating func recordStaleDiscard(generation: UInt64, at timestamp: TimeInterval) {
        guard let index = index(for: generation) else { return }
        _ = sanitized(timestamp)
        guard entries[index].deepOutcome != .ready else { return }
        entries[index].deepOutcome = .staleDiscarded
    }

    mutating func invalidate(
        generation: UInt64,
        outcome: MeetingTimingInvalidationOutcome,
        at timestamp: TimeInterval
    ) {
        guard
            let index = index(for: generation),
            entries[index].invalidationOutcome == nil
        else {
            return
        }
        _ = sanitized(timestamp)
        entries[index].invalidationOutcome = outcome
    }

    mutating func recordUserDismissed(generation: UInt64, at timestamp: TimeInterval) {
        guard let index = index(for: generation), !entries[index].userDismissed else { return }
        _ = sanitized(timestamp)
        entries[index].userDismissed = true
    }

    func snapshot() -> MeetingTimingSnapshot {
        let samples = entries.map { entry in
            MeetingTurnTimingSample(
                sequence: entry.sequence,
                turnStableToBridgeReadySeconds: duration(
                    from: entry.turnStartedAt,
                    to: entry.bridgeReadyAt
                ),
                confirmedLocalSpeechObserved: entry.confirmedLocalSpeechObserved,
                bridgeToConfirmedLocalSpeechMarginSeconds: margin(
                    from: entry.bridgeReadyAt,
                    to: entry.confirmedLocalSpeechAt
                ),
                turnStableToVerifiedDeepReadySeconds: duration(
                    from: entry.turnStartedAt,
                    to: entry.verifiedDeepReadyAt
                ),
                deepOutcome: entry.deepOutcome,
                invalidationOutcome: entry.invalidationOutcome,
                userDismissed: entry.userDismissed
            )
        }
        return MeetingTimingSnapshot(
            samples: samples,
            retainedTurnCount: samples.count,
            droppedTurnCount: droppedTurnCount,
            staleDiscardedCount: samples.count { $0.deepOutcome == .staleDiscarded },
            invalidatedTurnCount: samples.count { $0.invalidationOutcome != nil },
            userDismissedCount: samples.count { $0.userDismissed },
            targets: Self.targetEvaluation(
                for: samples,
                droppedTurnCount: droppedTurnCount
            )
        )
    }

    mutating func clear() {
        entries.removeAll(keepingCapacity: false)
        nextSequence = 1
        droppedTurnCount = 0
    }

    fileprivate static func targetEvaluation(
        for samples: [MeetingTurnTimingSample],
        droppedTurnCount: Int
    ) -> MeetingTimingTargetEvaluation {
        let bridgeDeadline = 1.25
        let bridgeDurations = samples.compactMap(\.turnStableToBridgeReadySeconds)
        let bridgeMissingSampleCount = samples.count { sample in
            sample.turnStableToBridgeReadySeconds == nil
                && (sample.confirmedLocalSpeechObserved
                    || sample.invalidationOutcome != nil
                    || sample.deepOutcome != .pending)
        }
        let bridgeWorst = bridgeDurations.max()
        let bridgeStatus: MeetingTimingTargetStatus =
            droppedTurnCount > 0
            ? .notEvaluated
            : bridgeMissingSampleCount > 0
                ? .missed
                : targetStatus(observed: bridgeWorst, target: bridgeDeadline)

        let beforeSpeechTarget = 0.85
        let confirmedSpeechSamples = samples.filter(\.confirmedLocalSpeechObserved)
        let speechMargins = confirmedSpeechSamples.compactMap(
            \.bridgeToConfirmedLocalSpeechMarginSeconds
        )
        let beforeSpeechRate: Double? =
            confirmedSpeechSamples.isEmpty
            ? nil
            : Double(speechMargins.count { $0 >= 0 }) / Double(confirmedSpeechSamples.count)
        let beforeSpeechStatus: MeetingTimingTargetStatus =
            droppedTurnCount > 0
            ? .notEvaluated
            : targetStatus(
                observed: beforeSpeechRate,
                minimum: beforeSpeechTarget
            )

        let deepP50Target = 10.0
        let deepP95Target = 25.0
        let deepDurations = samples.compactMap(\.turnStableToVerifiedDeepReadySeconds).sorted()
        let deepP50 = percentile(0.50, values: deepDurations)
        let deepP95 = percentile(0.95, values: deepDurations)

        return MeetingTimingTargetEvaluation(
            bridgeReadyDeadlineSeconds: bridgeDeadline,
            bridgeReadySampleCount: bridgeDurations.count,
            bridgeReadyMissingSampleCount: bridgeMissingSampleCount,
            bridgeReadyWorstSeconds: bridgeWorst,
            bridgeReadyDeadlineStatus: bridgeStatus,
            bridgeBeforeLocalSpeechTargetRate: beforeSpeechTarget,
            bridgeBeforeLocalSpeechSampleCount: confirmedSpeechSamples.count,
            bridgeBeforeLocalSpeechObservedRate: beforeSpeechRate,
            bridgeBeforeLocalSpeechStatus: beforeSpeechStatus,
            verifiedDeepP50TargetSeconds: deepP50Target,
            verifiedDeepP95TargetSeconds: deepP95Target,
            verifiedDeepSampleCount: deepDurations.count,
            verifiedDeepObservedP50Seconds: deepP50,
            verifiedDeepObservedP95Seconds: deepP95,
            verifiedDeepP50Status: droppedTurnCount > 0
                ? .notEvaluated
                : targetStatus(observed: deepP50, target: deepP50Target),
            verifiedDeepP95Status: droppedTurnCount > 0
                ? .notEvaluated
                : targetStatus(observed: deepP95, target: deepP95Target)
        )
    }

    private func index(for generation: UInt64) -> Int? {
        entries.firstIndex { $0.generation == generation }
    }

    private func sanitized(_ timestamp: TimeInterval) -> TimeInterval {
        timestamp.isFinite ? max(0, timestamp) : 0
    }

    private func duration(
        from start: TimeInterval,
        to end: TimeInterval?
    ) -> TimeInterval? {
        end.map { max(0, $0 - start) }
    }

    private func margin(
        from bridge: TimeInterval?,
        to localSpeech: TimeInterval?
    ) -> TimeInterval? {
        guard let bridge, let localSpeech else { return nil }
        return localSpeech - bridge
    }

    private static func percentile(
        _ percentile: Double,
        values: [TimeInterval]
    ) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let rank = max(1, Int(ceil(percentile * Double(values.count))))
        return values[min(rank - 1, values.count - 1)]
    }

    private static func targetStatus(
        observed: Double?,
        target: Double
    ) -> MeetingTimingTargetStatus {
        guard let observed else { return .notEvaluated }
        return observed <= target ? .met : .missed
    }

    private static func targetStatus(
        observed: Double?,
        minimum: Double
    ) -> MeetingTimingTargetStatus {
        guard let observed else { return .notEvaluated }
        return observed >= minimum ? .met : .missed
    }
}
