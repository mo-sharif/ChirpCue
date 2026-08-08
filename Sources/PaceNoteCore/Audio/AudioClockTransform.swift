import AVFoundation
import CoreMedia
import Foundation

struct AudioClockTransformConfiguration: Equatable, Sendable {
    let maximumAnchorCount: Int
    let minimumRegressionAnchorCount: Int
    let maximumCadenceError: TimeInterval
    let maximumRegressionResidual: TimeInterval

    init(
        maximumAnchorCount: Int = 512,
        minimumRegressionAnchorCount: Int = 4,
        maximumCadenceError: TimeInterval = 0.080,
        maximumRegressionResidual: TimeInterval = 0.040
    ) {
        precondition(maximumAnchorCount >= 2)
        precondition(minimumRegressionAnchorCount >= 2)
        precondition(minimumRegressionAnchorCount <= maximumAnchorCount)
        precondition(maximumCadenceError > 0)
        precondition(maximumRegressionResidual > 0)
        self.maximumAnchorCount = maximumAnchorCount
        self.minimumRegressionAnchorCount = minimumRegressionAnchorCount
        self.maximumCadenceError = maximumCadenceError
        self.maximumRegressionResidual = maximumRegressionResidual
    }
}

struct AudioClockEstimate: Equatable, Sendable {
    let sourceFramePosition: Double
    let mappedHostSeconds: TimeInterval
    let driftPartsPerMillion: Double?
    let regressionResidual: TimeInterval
    let isRegressionWarmedUp: Bool
}

enum AudioClockObservation: Equatable, Sendable {
    case accepted(AudioClockEstimate)
    case discontinuity
}

/// A bounded sample-frame-to-Core-Audio-host-time transform for one capture lane.
/// It performs no DSP and retains no audio. A caller must reset or fail closed
/// when `observe` reports a discontinuity.
struct AudioClockTransform: Sendable {
    private struct Anchor: Sendable {
        let sourceFramePosition: Double
        let hostSeconds: TimeInterval
    }

    private struct Regression {
        let baseSourceFramePosition: Double
        let baseHostSeconds: TimeInterval
        let intercept: Double
        let secondsPerFrame: Double

        func hostSeconds(for sourceFramePosition: Double) -> TimeInterval {
            baseHostSeconds + intercept
                + secondsPerFrame * (sourceFramePosition - baseSourceFramePosition)
        }
    }

    private let configuration: AudioClockTransformConfiguration
    private var anchors: [Anchor] = []
    private var nextSourceFramePosition = 0.0
    private var nominalSampleRate: Double?

    init(configuration: AudioClockTransformConfiguration = .init()) {
        self.configuration = configuration
        anchors.reserveCapacity(configuration.maximumAnchorCount)
    }

    mutating func observe(
        hostTime: HostTimestamp,
        frameCount: UInt32,
        sampleRate: Double
    ) -> AudioClockObservation {
        guard sampleRate.isFinite, sampleRate > 0, frameCount > 0 else {
            reset()
            return .discontinuity
        }

        let hostSeconds = hostTime.seconds
        guard hostSeconds.isFinite else {
            reset()
            return .discontinuity
        }

        guard let nominalSampleRate else {
            return seed(
                hostSeconds: hostSeconds,
                frameCount: frameCount,
                sampleRate: sampleRate
            )
        }
        guard nominalSampleRate == sampleRate, let previous = anchors.last else {
            _ = seed(
                hostSeconds: hostSeconds,
                frameCount: frameCount,
                sampleRate: sampleRate
            )
            return .discontinuity
        }

        let sourceFramePosition = nextSourceFramePosition
        let hostDelta = hostSeconds - previous.hostSeconds
        let sourceFrameDelta = sourceFramePosition - previous.sourceFramePosition
        let expectedHostDelta = sourceFrameDelta / sampleRate
        guard hostDelta > 0,
            sourceFrameDelta > 0,
            abs(hostDelta - expectedHostDelta) <= configuration.maximumCadenceError
        else {
            _ = seed(
                hostSeconds: hostSeconds,
                frameCount: frameCount,
                sampleRate: sampleRate
            )
            return .discontinuity
        }

        anchors.append(
            Anchor(
                sourceFramePosition: sourceFramePosition,
                hostSeconds: hostSeconds
            )
        )
        nextSourceFramePosition += Double(frameCount)
        if anchors.count > configuration.maximumAnchorCount {
            anchors.removeFirst(anchors.count - configuration.maximumAnchorCount)
        }

        guard let regression = regression() else {
            return .accepted(
                AudioClockEstimate(
                    sourceFramePosition: sourceFramePosition,
                    mappedHostSeconds: hostSeconds,
                    driftPartsPerMillion: nil,
                    regressionResidual: 0,
                    isRegressionWarmedUp: false
                )
            )
        }

        let mappedHostSeconds = regression.hostSeconds(for: sourceFramePosition)
        let residual = abs(mappedHostSeconds - hostSeconds)
        let warmedUp = anchors.count >= configuration.minimumRegressionAnchorCount
        guard !warmedUp || residual <= configuration.maximumRegressionResidual else {
            _ = seed(
                hostSeconds: hostSeconds,
                frameCount: frameCount,
                sampleRate: sampleRate
            )
            return .discontinuity
        }

        return .accepted(
            AudioClockEstimate(
                sourceFramePosition: sourceFramePosition,
                mappedHostSeconds: mappedHostSeconds,
                driftPartsPerMillion: (regression.secondsPerFrame * sampleRate - 1) * 1_000_000,
                regressionResidual: residual,
                isRegressionWarmedUp: warmedUp
            )
        )
    }

    func mappedHostSeconds(forSourceFramePosition sourceFramePosition: Double) -> TimeInterval? {
        guard sourceFramePosition.isFinite else { return nil }
        if let regression = regression() {
            return regression.hostSeconds(for: sourceFramePosition)
        }
        guard let first = anchors.first, let nominalSampleRate else { return nil }
        return first.hostSeconds
            + (sourceFramePosition - first.sourceFramePosition) / nominalSampleRate
    }

    mutating func reset() {
        anchors.removeAll(keepingCapacity: true)
        nextSourceFramePosition = 0
        nominalSampleRate = nil
    }

    private mutating func seed(
        hostSeconds: TimeInterval,
        frameCount: UInt32,
        sampleRate: Double
    ) -> AudioClockObservation {
        reset()
        nominalSampleRate = sampleRate
        anchors.append(Anchor(sourceFramePosition: 0, hostSeconds: hostSeconds))
        nextSourceFramePosition = Double(frameCount)
        return .accepted(
            AudioClockEstimate(
                sourceFramePosition: 0,
                mappedHostSeconds: hostSeconds,
                driftPartsPerMillion: nil,
                regressionResidual: 0,
                isRegressionWarmedUp: false
            )
        )
    }

    private func regression() -> Regression? {
        guard anchors.count >= 2, let first = anchors.first else { return nil }

        let normalized = anchors.map { anchor in
            (
                source: anchor.sourceFramePosition - first.sourceFramePosition,
                host: anchor.hostSeconds - first.hostSeconds
            )
        }
        let count = Double(normalized.count)
        let meanSource = normalized.reduce(0) { $0 + $1.source } / count
        let meanHost = normalized.reduce(0) { $0 + $1.host } / count
        let covariance = normalized.reduce(0) {
            $0 + ($1.source - meanSource) * ($1.host - meanHost)
        }
        let sourceVariance = normalized.reduce(0) {
            $0 + ($1.source - meanSource) * ($1.source - meanSource)
        }
        guard sourceVariance > 0 else { return nil }
        let secondsPerFrame = covariance / sourceVariance
        guard secondsPerFrame.isFinite, secondsPerFrame > 0 else { return nil }

        return Regression(
            baseSourceFramePosition: first.sourceFramePosition,
            baseHostSeconds: first.hostSeconds,
            intercept: meanHost - secondsPerFrame * meanSource,
            secondsPerFrame: secondsPerFrame
        )
    }
}

struct AnalyzerInputTimelineConfiguration: Equatable, Sendable {
    let maximumForwardCorrection: TimeInterval

    init(maximumForwardCorrection: TimeInterval = 0.040) {
        precondition(maximumForwardCorrection >= 0)
        self.maximumForwardCorrection = maximumForwardCorrection
    }
}

struct AnalyzerInputSchedule: Equatable, Sendable {
    let startTime: CMTime
    let endTime: CMTime
    let forwardCorrection: TimeInterval
}

enum AnalyzerInputTimelineError: Error, Equatable, Sendable {
    case invalidTime
    case excessiveCorrection
}

/// Enforces Speech.AnalyzerInput's non-overlapping time-code contract. Small
/// conversion-rounding overlaps are shifted forward, but the bounded shift may
/// never hide clock drift large enough to threaten the two-lane 80 ms target.
struct AnalyzerInputTimeline: Sendable {
    private let configuration: AnalyzerInputTimelineConfiguration
    private var lastEndSeconds: TimeInterval?

    init(configuration: AnalyzerInputTimelineConfiguration = .init()) {
        self.configuration = configuration
    }

    mutating func schedule(
        rawStartTime: CMTime,
        frameCount: AVAudioFrameCount,
        sampleRate: Double
    ) throws -> AnalyzerInputSchedule {
        let rawStartSeconds = rawStartTime.seconds
        guard rawStartTime.isValid,
            !rawStartTime.isIndefinite,
            rawStartSeconds.isFinite,
            rawStartSeconds >= 0,
            frameCount > 0,
            sampleRate.isFinite,
            sampleRate > 0
        else {
            throw AnalyzerInputTimelineError.invalidTime
        }

        let duration = Double(frameCount) / sampleRate
        guard duration.isFinite, duration > 0 else {
            throw AnalyzerInputTimelineError.invalidTime
        }

        let scheduledStartSeconds = max(rawStartSeconds, lastEndSeconds ?? rawStartSeconds)
        let correction = scheduledStartSeconds - rawStartSeconds
        guard correction <= configuration.maximumForwardCorrection else {
            throw AnalyzerInputTimelineError.excessiveCorrection
        }
        let endSeconds = scheduledStartSeconds + duration
        guard endSeconds.isFinite else { throw AnalyzerInputTimelineError.invalidTime }
        lastEndSeconds = endSeconds

        return AnalyzerInputSchedule(
            startTime: CMTime(seconds: scheduledStartSeconds, preferredTimescale: 1_000_000_000),
            endTime: CMTime(seconds: endSeconds, preferredTimescale: 1_000_000_000),
            forwardCorrection: correction
        )
    }

    mutating func reset() {
        lastEndSeconds = nil
    }
}

enum SpeechAudioClockTimelineError: Error, Equatable, Sendable {
    case discontinuity
    case invalidResultRange
}

/// Connects the source-frame clock transform to Speech's contiguous analyzer
/// timeline. The returned schedule validates the conversion cadence; callers do
/// not pass its timecode to live `AnalyzerInput` values. Speech's result ranges
/// are mapped back into the shared Core Audio host-time domain through the
/// measured transform. This prevents normal device-clock drift from accumulating
/// as an ever-growing overlap correction.
struct SpeechAudioClockTimeline: Sendable {
    private var clockTransform: AudioClockTransform
    private var analyzerTimeline: AnalyzerInputTimeline
    private var sourceSampleRate: Double?

    init(
        clockConfiguration: AudioClockTransformConfiguration = .init(),
        analyzerConfiguration: AnalyzerInputTimelineConfiguration = .init()
    ) {
        self.clockTransform = AudioClockTransform(configuration: clockConfiguration)
        self.analyzerTimeline = AnalyzerInputTimeline(configuration: analyzerConfiguration)
    }

    mutating func schedule(
        hostTime: HostTimestamp,
        sourceFrameCount: UInt32,
        sourceSampleRate: Double,
        analyzerFrameCount: AVAudioFrameCount,
        analyzerSampleRate: Double
    ) throws -> AnalyzerInputSchedule {
        let estimate: AudioClockEstimate
        switch clockTransform.observe(
            hostTime: hostTime,
            frameCount: sourceFrameCount,
            sampleRate: sourceSampleRate
        ) {
        case .accepted(let accepted):
            estimate = accepted
        case .discontinuity:
            throw SpeechAudioClockTimelineError.discontinuity
        }

        if let establishedSampleRate = self.sourceSampleRate {
            guard establishedSampleRate == sourceSampleRate else {
                throw SpeechAudioClockTimelineError.discontinuity
            }
        } else {
            self.sourceSampleRate = sourceSampleRate
        }

        let sourceFrameSeconds = estimate.sourceFramePosition / sourceSampleRate
        guard sourceFrameSeconds.isFinite, sourceFrameSeconds >= 0 else {
            throw SpeechAudioClockTimelineError.discontinuity
        }
        do {
            return try analyzerTimeline.schedule(
                rawStartTime: CMTime(
                    seconds: sourceFrameSeconds,
                    preferredTimescale: 1_000_000_000
                ),
                frameCount: analyzerFrameCount,
                sampleRate: analyzerSampleRate
            )
        } catch {
            throw SpeechAudioClockTimelineError.discontinuity
        }
    }

    func mapResultRangeToHostTime(_ range: CMTimeRange) throws -> HostTimeRange {
        guard let sourceSampleRate,
            range.isValid,
            range.start.isValid,
            !range.start.isIndefinite,
            range.duration.isValid,
            !range.duration.isIndefinite
        else {
            throw SpeechAudioClockTimelineError.invalidResultRange
        }

        let startSeconds = range.start.seconds
        let durationSeconds = range.duration.seconds
        guard startSeconds.isFinite,
            startSeconds >= 0,
            durationSeconds.isFinite,
            durationSeconds >= 0
        else {
            throw SpeechAudioClockTimelineError.invalidResultRange
        }

        let startFramePosition = startSeconds * sourceSampleRate
        let endFramePosition = (startSeconds + durationSeconds) * sourceSampleRate
        guard
            let mappedStart = clockTransform.mappedHostSeconds(
                forSourceFramePosition: startFramePosition
            ),
            let mappedEnd = clockTransform.mappedHostSeconds(
                forSourceFramePosition: endFramePosition
            ),
            mappedStart.isFinite,
            mappedEnd.isFinite,
            mappedStart >= 0,
            mappedEnd >= mappedStart
        else {
            throw SpeechAudioClockTimelineError.invalidResultRange
        }

        return HostTimeRange(
            start: HostTimestamp(ticks: AVAudioTime.hostTime(forSeconds: mappedStart)),
            end: HostTimestamp(ticks: AVAudioTime.hostTime(forSeconds: mappedEnd))
        )
    }

    mutating func reset() {
        clockTransform.reset()
        analyzerTimeline.reset()
        sourceSampleRate = nil
    }
}
