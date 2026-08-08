import AVFoundation
import CoreMedia
import Foundation
import Speech
import Synchronization

public enum SpeechAssetAvailability: Equatable, Sendable {
    case unsupported
    case downloadRequired
    case downloading
    case installed
}

public struct SpeechAssetPreparation: Equatable, Sendable {
    public let localeIdentifier: String
    public let installedDuringPreparation: Bool
    public let reserved: Bool

    public init(
        localeIdentifier: String,
        installedDuringPreparation: Bool,
        reserved: Bool
    ) {
        self.localeIdentifier = localeIdentifier
        self.installedDuringPreparation = installedDuringPreparation
        self.reserved = reserved
    }
}

public protocol SpeechAssetPreparing: Sendable {
    func availability(localeIdentifier: String) async -> SpeechAssetAvailability
    func prepare(localeIdentifier: String) async throws -> SpeechAssetPreparation
}

public enum SpeechAssetError: Error, Equatable, LocalizedError, Sendable {
    case transcriberUnavailable
    case localeUnsupported
    case installationIncomplete

    public var errorDescription: String? {
        switch self {
        case .transcriberUnavailable: "On-device transcription is unavailable."
        case .localeUnsupported: "The selected transcription locale is unsupported."
        case .installationIncomplete: "The on-device transcription asset is not installed."
        }
    }
}

public actor AppleSpeechAssetManager: SpeechAssetPreparing {
    public init() {}

    public func availability(localeIdentifier: String) async -> SpeechAssetAvailability {
        guard SpeechTranscriber.isAvailable,
            let locale = await supportedLocale(localeIdentifier)
        else {
            return .unsupported
        }

        let transcriber = makePaceNoteTranscriber(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .unsupported:
            return SpeechAssetAvailability.unsupported
        case .supported:
            return SpeechAssetAvailability.downloadRequired
        case .downloading:
            return SpeechAssetAvailability.downloading
        case .installed:
            return SpeechAssetAvailability.installed
        @unknown default:
            return SpeechAssetAvailability.unsupported
        }
    }

    public func prepare(localeIdentifier: String) async throws -> SpeechAssetPreparation {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechAssetError.transcriberUnavailable
        }
        guard let locale = await supportedLocale(localeIdentifier) else {
            throw SpeechAssetError.localeUnsupported
        }

        let transcriber = makePaceNoteTranscriber(locale: locale)
        let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        )
        if let request {
            try await request.downloadAndInstall()
        }

        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw SpeechAssetError.installationIncomplete
        }

        let alreadyReserved = await AssetInventory.reservedLocales.contains(locale)
        let reserved: Bool
        if alreadyReserved {
            reserved = true
        } else {
            reserved = try await AssetInventory.reserve(locale: locale)
        }
        return SpeechAssetPreparation(
            localeIdentifier: locale.identifier,
            installedDuringPreparation: request != nil,
            reserved: reserved
        )
    }

    private func supportedLocale(_ identifier: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: identifier)
        )
    }
}

public enum TranscriptStability: String, Codable, Sendable {
    case volatile
    case final
}

public struct ProgressiveTranscriptResult: Equatable, Sendable {
    public let lane: AudioLane
    public let text: String
    public let hostTimeRange: HostTimeRange?
    public let stability: TranscriptStability
    public let confidence: Double?

    public init(
        lane: AudioLane,
        text: String,
        hostTimeRange: HostTimeRange?,
        stability: TranscriptStability,
        confidence: Double?
    ) {
        self.lane = lane
        self.text = text
        self.hostTimeRange = hostTimeRange
        self.stability = stability
        self.confidence = confidence
    }
}

public enum SpeechTranscriptionFailure: String, Codable, Sendable {
    case analyzerFailed
    case conversionFailed
    case invalidAudioBuffer
    case assetUnavailable
}

public enum SpeechTranscriptionEvent: Equatable, Sendable {
    case started(lane: AudioLane, localeIdentifier: String)
    case result(ProgressiveTranscriptResult)
    case gap(AudioGap)
    case routeChanged(previous: AudioRouteDescriptor, current: AudioRouteDescriptor?)
    case failed(lane: AudioLane, reason: SpeechTranscriptionFailure)
    case stopped(AudioLane)
}

public protocol AudioTranscribing: Sendable {
    var lane: AudioLane { get }
    func events() async -> AsyncStream<SpeechTranscriptionEvent>
    func start(
        audioEvents: AsyncStream<AudioCaptureEvent>,
        localeIdentifier: String
    ) async throws
    func stop() async
}

public enum SpeechTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case alreadyRunning
    case assetUnavailable(SpeechAssetAvailability)
    case localeUnsupported
    case analyzerFormatUnavailable
    case invalidAudioBuffer
    case conversionFailed

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "The transcription lane is already running."
        case .assetUnavailable: "The on-device transcription asset is unavailable."
        case .localeUnsupported: "The selected transcription locale is unsupported."
        case .analyzerFormatUnavailable: "No compatible transcription audio format is available."
        case .invalidAudioBuffer: "Captured audio could not be reconstructed safely."
        case .conversionFailed: "Captured audio could not be converted for transcription."
        }
    }
}

public actor AppleSpeechTranscriptionService: AudioTranscribing {
    public nonisolated let lane: AudioLane

    private let assets: any SpeechAssetPreparing
    private var continuation: AsyncStream<SpeechTranscriptionEvent>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var analyzerInput: DiscardingAsyncStreamBuffer<AnalyzerInput>?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var audioClockTimeline = SpeechAudioClockTimeline()
    private var timingBlocked = false
    private var sessionID: UUID?

    public init(
        lane: AudioLane,
        assets: any SpeechAssetPreparing = AppleSpeechAssetManager()
    ) {
        self.lane = lane
        self.assets = assets
    }

    public func events() -> AsyncStream<SpeechTranscriptionEvent> {
        continuation?.finish()
        let pair = AsyncStream.makeStream(
            of: SpeechTranscriptionEvent.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        continuation = pair.continuation
        return pair.stream
    }

    public func start(
        audioEvents: AsyncStream<AudioCaptureEvent>,
        localeIdentifier: String
    ) async throws {
        guard analyzer == nil else { throw SpeechTranscriptionError.alreadyRunning }
        let availability = await assets.availability(localeIdentifier: localeIdentifier)
        guard availability == .installed else {
            throw SpeechTranscriptionError.assetUnavailable(availability)
        }
        guard
            let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: localeIdentifier)
            )
        else {
            throw SpeechTranscriptionError.localeUnsupported
        }

        let newTranscriber = makePaceNoteTranscriber(locale: locale)
        guard
            let newAnalyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [newTranscriber]
            )
        else {
            throw SpeechTranscriptionError.analyzerFormatUnavailable
        }

        let newAnalyzer = SpeechAnalyzer(modules: [newTranscriber])
        try await newAnalyzer.prepareToAnalyze(in: newAnalyzerFormat)
        let inputBuffer = DiscardingAsyncStreamBuffer<AnalyzerInput>(
            maximumCount: 32,
            discard: { Self.scrubAnalyzerInput(&$0) }
        )
        let inputStream = inputBuffer.stream()
        let newSessionID = UUID()

        analyzer = newAnalyzer
        transcriber = newTranscriber
        analyzerFormat = newAnalyzerFormat
        analyzerInput = inputBuffer
        audioClockTimeline.reset()
        timingBlocked = false
        sessionID = newSessionID

        analysisTask = Task { [weak self] in
            do {
                _ = try await newAnalyzer.analyzeSequence(inputStream)
            } catch is CancellationError {
                return
            } catch {
                await self?.handleFailure(.analyzerFailed, sessionID: newSessionID)
            }
        }

        resultTask = Task { [weak self] in
            do {
                for try await result in newTranscriber.results {
                    guard let self else { return }
                    await self.handle(result: result, sessionID: newSessionID)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.handleFailure(.analyzerFailed, sessionID: newSessionID)
            }
        }

        captureTask = Task { [weak self] in
            for await event in audioEvents {
                guard let self else { return }
                await self.handle(captureEvent: event, sessionID: newSessionID)
            }
        }

        yield(.started(lane: lane, localeIdentifier: locale.identifier))
    }

    public func stop() async {
        await stop(waitForCaptureTask: true)
    }

    private func stop(waitForCaptureTask: Bool) async {
        sessionID = nil

        let captureTask = self.captureTask
        self.captureTask = nil
        captureTask?.cancel()
        if waitForCaptureTask { await captureTask?.value }

        analyzerInput?.finish()
        analyzerInput = nil

        let analysisTask = self.analysisTask
        let resultTask = self.resultTask
        self.analysisTask = nil
        self.resultTask = nil
        analysisTask?.cancel()
        resultTask?.cancel()
        if let analyzer { await analyzer.cancelAndFinishNow() }
        await analysisTask?.value
        await resultTask?.value

        self.analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        converter = nil
        converterInputFormat = nil
        audioClockTimeline.reset()
        timingBlocked = false
        let eventContinuation = continuation
        continuation = nil
        eventContinuation?.yield(.stopped(lane))
        eventContinuation?.finish()
    }

    private func handle(
        captureEvent: AudioCaptureEvent,
        sessionID: UUID
    ) async {
        guard self.sessionID == sessionID else { return }
        switch captureEvent {
        case .started(let route):
            guard route.lane == lane else { return }

        case .audio(let chunk):
            guard chunk.lane == lane else { return }
            do {
                try feed(chunk)
            } catch is AudioClockPipelineError {
                blockTiming(detectedAt: chunk.hostTime)
            } catch SpeechTranscriptionError.invalidAudioBuffer {
                invalidateTiming()
                yield(.failed(lane: lane, reason: .invalidAudioBuffer))
            } catch {
                invalidateTiming()
                yield(.failed(lane: lane, reason: .conversionFailed))
            }

        case .gap(let gap):
            guard gap.lane == lane else { return }
            invalidateTiming()
            yield(.gap(gap))

        case .routeChanged(let previous, let current):
            guard previous.lane == lane else { return }
            blockTiming(detectedAt: .now)
            yield(.routeChanged(previous: previous, current: current))

        case .stopped(let stoppedLane):
            guard stoppedLane == lane else { return }
            await stop(waitForCaptureTask: false)
        }
    }

    private func feed(_ chunk: CapturedAudioChunk) throws {
        guard !timingBlocked, let analyzerFormat, let analyzerInput else { return }
        let source = try Self.makePCMBuffer(from: chunk)
        let converted = try convertedBuffer(source, to: analyzerFormat)

        let schedule: AnalyzerInputSchedule
        do {
            schedule = try audioClockTimeline.schedule(
                hostTime: chunk.hostTime,
                sourceFrameCount: chunk.frameCount,
                sourceSampleRate: chunk.format.sampleRate,
                analyzerFrameCount: converted.frameLength,
                analyzerSampleRate: converted.format.sampleRate
            )
        } catch {
            throw AudioClockPipelineError.discontinuity
        }
        let result = analyzerInput.yield(
            AnalyzerInput(buffer: converted, bufferStartTime: schedule.startTime)
        )
        if result == .droppedOldest {
            yield(
                .gap(
                    AudioGap(
                        lane: lane,
                        reason: .bufferOverflow,
                        detectedAt: chunk.hostTime,
                        droppedChunkCount: 1
                    )
                )
            )
        }
    }

    private func convertedBuffer(
        _ input: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        if input.format == outputFormat {
            return input
        }

        if converter == nil || converterInputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            converterInputFormat = input.format
        }
        guard let converter else { throw SpeechTranscriptionError.conversionFailed }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(
            max(1, ceil(Double(input.frameLength) * ratio) + 32)
        )
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            )
        else {
            throw SpeechTranscriptionError.conversionFailed
        }

        let inputProvider = OneShotConverterInput(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }
        guard conversionError == nil,
            status == .haveData || status == .inputRanDry,
            output.frameLength > 0
        else {
            throw SpeechTranscriptionError.conversionFailed
        }
        return output
    }

    private nonisolated static func makePCMBuffer(
        from chunk: CapturedAudioChunk
    ) throws -> AVAudioPCMBuffer {
        var streamDescription = chunk.format.streamDescription
        guard let format = AVAudioFormat(streamDescription: &streamDescription),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: chunk.frameCount
            )
        else {
            throw SpeechTranscriptionError.invalidAudioBuffer
        }
        buffer.frameLength = chunk.frameCount

        let destinations = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        guard destinations.count == chunk.planes.count else {
            throw SpeechTranscriptionError.invalidAudioBuffer
        }

        for (destination, plane) in zip(destinations, chunk.planes) {
            guard destination.mNumberChannels == plane.channelCount,
                let data = destination.mData,
                plane.data.count == Int(destination.mDataByteSize)
            else {
                throw SpeechTranscriptionError.invalidAudioBuffer
            }
            plane.data.copyBytes(
                to: data.assumingMemoryBound(to: UInt8.self),
                count: plane.data.count
            )
        }
        return buffer
    }

    nonisolated static func scrubAnalyzerInput(_ input: inout AnalyzerInput) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            input.buffer.mutableAudioBufferList
        )
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            data.initializeMemory(
                as: UInt8.self,
                repeating: 0,
                count: Int(buffer.mDataByteSize)
            )
        }
        input.buffer.frameLength = 0
    }

    private func handle(
        result: SpeechTranscriber.Result,
        sessionID: UUID
    ) {
        guard self.sessionID == sessionID, !timingBlocked else { return }
        let text = String(result.text.characters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let confidenceValues = result.text.runs.compactMap {
            $0[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
        }
        let confidence =
            confidenceValues.isEmpty
            ? nil
            : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
        guard let mappedRange = mapToHostTime(result.range) else {
            blockTiming(detectedAt: .now)
            return
        }
        yield(
            .result(
                ProgressiveTranscriptResult(
                    lane: lane,
                    text: text,
                    hostTimeRange: mappedRange,
                    stability: result.isFinal ? .final : .volatile,
                    confidence: confidence
                )
            )
        )
    }

    private func mapToHostTime(_ range: CMTimeRange) -> HostTimeRange? {
        guard !timingBlocked else { return nil }
        return try? audioClockTimeline.mapResultRangeToHostTime(range)
    }

    private func blockTiming(detectedAt: HostTimestamp) {
        guard invalidateTiming() else { return }
        yield(
            .gap(
                AudioGap(
                    lane: lane,
                    reason: .clockDiscontinuity,
                    detectedAt: detectedAt
                )
            )
        )
    }

    @discardableResult
    private func invalidateTiming() -> Bool {
        guard !timingBlocked else { return false }
        timingBlocked = true
        audioClockTimeline.reset()
        return true
    }

    private func handleFailure(
        _ reason: SpeechTranscriptionFailure,
        sessionID: UUID
    ) {
        guard self.sessionID == sessionID else { return }
        yield(.failed(lane: lane, reason: reason))
    }

    private func yield(_ event: SpeechTranscriptionEvent) {
        _ = continuation?.yield(event)
    }
}

private enum AudioClockPipelineError: Error {
    case discontinuity
}

private func makePaceNoteTranscriber(locale: Locale) -> SpeechTranscriber {
    let preset = SpeechTranscriber.Preset.timeIndexedProgressiveTranscription
    return SpeechTranscriber(
        locale: locale,
        transcriptionOptions: preset.transcriptionOptions,
        reportingOptions: preset.reportingOptions,
        attributeOptions: preset.attributeOptions.union([.transcriptionConfidence])
    )
}

private final class OneShotConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let consumed = Atomic<Bool>(false)

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        if consumed.exchange(true, ordering: .acquiringAndReleasing) {
            status.pointee = .noDataNow
            return nil
        }
        status.pointee = .haveData
        return buffer
    }
}
