import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

public enum AudioLane: String, Codable, CaseIterable, Sendable {
    case microphone
    case output
}

public struct HostTimestamp: Codable, Hashable, Comparable, Sendable {
    public let ticks: UInt64

    public init(ticks: UInt64) {
        self.ticks = ticks
    }

    public init?(audioTime: AVAudioTime) {
        guard audioTime.isHostTimeValid else { return nil }
        self.init(ticks: audioTime.hostTime)
    }

    public init?(audioTimeStamp: AudioTimeStamp) {
        guard audioTimeStamp.mFlags.contains(.hostTimeValid) else { return nil }
        self.init(ticks: audioTimeStamp.mHostTime)
    }

    public var cmTime: CMTime {
        CMClockMakeHostTimeFromSystemUnits(ticks)
    }

    public var seconds: TimeInterval {
        AVAudioTime.seconds(forHostTime: ticks)
    }

    public static var now: Self {
        Self(ticks: AudioGetCurrentHostTime())
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.ticks < rhs.ticks
    }

    public static func fromHostCMTime(_ time: CMTime) -> Self? {
        guard time.isValid, !time.isIndefinite else { return nil }
        return Self(ticks: CMClockConvertHostTimeToSystemUnits(time))
    }

    public func advanced(by duration: TimeInterval) -> Self {
        let result = CMTimeAdd(
            cmTime,
            CMTime(seconds: duration, preferredTimescale: 1_000_000_000)
        )
        return Self.fromHostCMTime(result) ?? self
    }
}

public struct HostTimeRange: Codable, Equatable, Sendable {
    public let start: HostTimestamp
    public let end: HostTimestamp

    public init(start: HostTimestamp, end: HostTimestamp) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: TimeInterval {
        max(0, end.seconds - start.seconds)
    }
}

public struct AudioFormatDescription: Codable, Equatable, Sendable {
    public let sampleRate: Double
    public let formatID: UInt32
    public let formatFlags: UInt32
    public let bytesPerPacket: UInt32
    public let framesPerPacket: UInt32
    public let bytesPerFrame: UInt32
    public let channelsPerFrame: UInt32
    public let bitsPerChannel: UInt32
    public let isInterleaved: Bool

    public init(
        sampleRate: Double,
        formatID: UInt32,
        formatFlags: UInt32,
        bytesPerPacket: UInt32,
        framesPerPacket: UInt32,
        bytesPerFrame: UInt32,
        channelsPerFrame: UInt32,
        bitsPerChannel: UInt32,
        isInterleaved: Bool
    ) {
        self.sampleRate = sampleRate
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.bytesPerPacket = bytesPerPacket
        self.framesPerPacket = framesPerPacket
        self.bytesPerFrame = bytesPerFrame
        self.channelsPerFrame = channelsPerFrame
        self.bitsPerChannel = bitsPerChannel
        self.isInterleaved = isInterleaved
    }

    public init(_ format: AVAudioFormat) {
        let stream = format.streamDescription.pointee
        self.init(stream, isInterleaved: format.isInterleaved)
    }

    public init(_ stream: AudioStreamBasicDescription) {
        self.init(
            stream,
            isInterleaved: stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        )
    }

    private init(_ stream: AudioStreamBasicDescription, isInterleaved: Bool) {
        self.init(
            sampleRate: stream.mSampleRate,
            formatID: stream.mFormatID,
            formatFlags: stream.mFormatFlags,
            bytesPerPacket: stream.mBytesPerPacket,
            framesPerPacket: stream.mFramesPerPacket,
            bytesPerFrame: stream.mBytesPerFrame,
            channelsPerFrame: stream.mChannelsPerFrame,
            bitsPerChannel: stream.mBitsPerChannel,
            isInterleaved: isInterleaved
        )
    }

    public var streamDescription: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: formatID,
            mFormatFlags: formatFlags,
            mBytesPerPacket: bytesPerPacket,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channelsPerFrame,
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )
    }

    public var isUsablePCM: Bool {
        sampleRate.isFinite
            && sampleRate > 0
            && formatID == kAudioFormatLinearPCM
            && bytesPerFrame > 0
            && channelsPerFrame > 0
    }
}

public struct CapturedAudioPlane: Codable, Equatable, Sendable {
    public let channelCount: UInt32
    public private(set) var data: Data

    public init(channelCount: UInt32, data: Data) {
        self.channelCount = channelCount
        self.data = data
    }

    mutating func scrub() {
        data.resetBytes(in: data.startIndex..<data.endIndex)
    }
}

public struct CapturedAudioChunk: Codable, Equatable, Sendable {
    public let lane: AudioLane
    public let hostTime: HostTimestamp
    public let frameCount: UInt32
    public let format: AudioFormatDescription
    public private(set) var planes: [CapturedAudioPlane]

    public init(
        lane: AudioLane,
        hostTime: HostTimestamp,
        frameCount: UInt32,
        format: AudioFormatDescription,
        planes: [CapturedAudioPlane]
    ) {
        self.lane = lane
        self.hostTime = hostTime
        self.frameCount = frameCount
        self.format = format
        self.planes = planes
    }

    public var duration: TimeInterval {
        guard format.sampleRate > 0 else { return 0 }
        return Double(frameCount) / format.sampleRate
    }

    public var hostTimeRange: HostTimeRange {
        HostTimeRange(start: hostTime, end: hostTime.advanced(by: duration))
    }

    public var byteCount: Int {
        planes.reduce(into: 0) { $0 += $1.data.count }
    }

    mutating func scrubAudioData() {
        for index in planes.indices { planes[index].scrub() }
    }

    func ownedCopy() -> CapturedAudioChunk {
        CapturedAudioChunk(
            lane: lane,
            hostTime: hostTime,
            frameCount: frameCount,
            format: format,
            planes: planes.map { plane in
                let copiedData = plane.data.withUnsafeBytes { Data($0) }
                return CapturedAudioPlane(channelCount: plane.channelCount, data: copiedData)
            }
        )
    }
}

public enum AudioRouteScope: String, Codable, Sendable {
    case defaultMicrophone
    case selectedProcesses
    case globalOutput
}

public struct AudioRouteDescriptor: Codable, Equatable, Sendable {
    public let lane: AudioLane
    public let scope: AudioRouteScope
    public let format: AudioFormatDescription
    public let selectedSourceCount: Int

    public init(
        lane: AudioLane,
        scope: AudioRouteScope,
        format: AudioFormatDescription,
        selectedSourceCount: Int = 1
    ) {
        self.lane = lane
        self.scope = scope
        self.format = format
        self.selectedSourceCount = selectedSourceCount
    }
}

public enum AudioGapReason: String, Codable, CaseIterable, Sendable {
    case callbackMissing
    case bufferOverflow
    case oversizedBuffer
    case invalidFormat
    case invalidTimestamp
    case clockDiscontinuity
    case routeChanged
    case captureFailed
}

public struct AudioGap: Codable, Equatable, Sendable {
    public let lane: AudioLane
    public let reason: AudioGapReason
    public let detectedAt: HostTimestamp
    public let droppedChunkCount: UInt64

    public init(
        lane: AudioLane,
        reason: AudioGapReason,
        detectedAt: HostTimestamp,
        droppedChunkCount: UInt64 = 0
    ) {
        self.lane = lane
        self.reason = reason
        self.detectedAt = detectedAt
        self.droppedChunkCount = droppedChunkCount
    }
}

public enum AudioCaptureEvent: Equatable, Sendable {
    case started(AudioRouteDescriptor)
    case audio(CapturedAudioChunk)
    case gap(AudioGap)
    case routeChanged(previous: AudioRouteDescriptor, current: AudioRouteDescriptor?)
    case stopped(AudioLane)

    func ownedForSensitiveBuffer() -> AudioCaptureEvent {
        guard case .audio(let chunk) = self else { return self }
        return .audio(chunk.ownedCopy())
    }

    mutating func scrubAudioData() {
        guard case .audio(var chunk) = self else { return }
        chunk.scrubAudioData()
        self = .audio(chunk)
    }
}

public struct AudioCaptureConfiguration: Equatable, Sendable {
    public let historyLimits: BoundedAudioBufferLimits
    public let drainInterval: Duration
    public let callbackTimeout: TimeInterval

    public init(
        historyLimits: BoundedAudioBufferLimits = .init(),
        drainInterval: Duration = .milliseconds(5),
        callbackTimeout: TimeInterval = 2
    ) {
        precondition(callbackTimeout > 0)
        self.historyLimits = historyLimits
        self.drainInterval = drainInterval
        self.callbackTimeout = callbackTimeout
    }
}

public protocol AudioCapturing: Sendable {
    var lane: AudioLane { get }
    func events() async -> AsyncStream<AudioCaptureEvent>
    func start() async throws
    func stop() async throws
}

public enum AudioPermissionStatus: String, Codable, Sendable {
    case notDetermined
    case denied
    case granted
}

public protocol MicrophonePermissionProviding: Sendable {
    func status() async -> AudioPermissionStatus
    func request() async -> AudioPermissionStatus
}

public struct SystemMicrophonePermissionProvider: MicrophonePermissionProviding {
    public init() {}

    public func status() async -> AudioPermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: .notDetermined
        case .denied: .denied
        case .granted: .granted
        @unknown default: .denied
        }
    }

    public func request() async -> AudioPermissionStatus {
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .granted : .denied
    }
}

public enum AudioCaptureError: Error, Equatable, LocalizedError, Sendable {
    case alreadyRunning(AudioLane)
    case permissionRequired
    case permissionDenied
    case invalidFormat(AudioLane)
    case sourceUnavailable
    case systemFailure(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning(let lane): "The \(lane.rawValue) capture lane is already running."
        case .permissionRequired: "Microphone permission has not been requested."
        case .permissionDenied: "Microphone permission was denied."
        case .invalidFormat(let lane): "The \(lane.rawValue) capture route has an invalid format."
        case .sourceUnavailable: "The selected meeting audio source is unavailable."
        case .systemFailure(let code): "Audio capture failed with system status \(code)."
        }
    }
}
