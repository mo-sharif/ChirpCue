import AVFoundation
import CoreAudio
import Speech
import XCTest

@testable import PaceNoteCore

final class AudioBufferTests: XCTestCase {
    func testHostTimestampUsesSameTicksForAVAudioAndCoreAudio() throws {
        let ticks = AVAudioTime.hostTime(forSeconds: 42)
        let avTime = AVAudioTime(hostTime: ticks)
        var coreTime = AudioTimeStamp()
        coreTime.mHostTime = ticks
        coreTime.mFlags = .hostTimeValid

        XCTAssertEqual(HostTimestamp(audioTime: avTime), HostTimestamp(ticks: ticks))
        XCTAssertEqual(HostTimestamp(audioTimeStamp: coreTime), HostTimestamp(ticks: ticks))
    }

    func testCurrentTimestampUsesCoreAudioHostClockDomain() {
        let before = AudioGetCurrentHostTime()
        let current = HostTimestamp.now.ticks
        let after = AudioGetCurrentHostTime()

        XCTAssertGreaterThanOrEqual(current, before)
        XCTAssertLessThanOrEqual(current, after)
    }

    func testRealtimeRingCopiesAudioAndScrubsAfterRead() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        buffer.frameLength = 4
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples[0] = 0.25
        samples[1] = -0.5
        samples[2] = 0.75
        samples[3] = -1

        let ring = RealtimeAudioRing(
            lane: .microphone,
            format: AudioFormatDescription(format),
            configuration: .init(
                slotCount: 2,
                maximumBytesPerSlot: 128,
                maximumPlanes: 2
            )
        )
        let timestamp = HostTimestamp(
            ticks: AVAudioTime.hostTime(forSeconds: 10)
        )

        XCTAssertTrue(
            ring.write(
                buffer.audioBufferList,
                frameCount: buffer.frameLength,
                hostTime: timestamp
            )
        )
        let chunk = try XCTUnwrap(ring.read())
        XCTAssertEqual(chunk.lane, .microphone)
        XCTAssertEqual(chunk.hostTime, timestamp)
        XCTAssertEqual(chunk.frameCount, 4)
        XCTAssertEqual(chunk.planes.count, 1)
        XCTAssertEqual(chunk.planes[0].data.count, 4 * MemoryLayout<Float>.size)
        XCTAssertNil(ring.read())
    }

    func testRealtimeRingReportsOverflowWithoutOverwritingUnreadAudio() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
        )
        buffer.frameLength = 1
        let ring = RealtimeAudioRing(
            lane: .output,
            format: AudioFormatDescription(format),
            configuration: .init(
                slotCount: 2,
                maximumBytesPerSlot: 64,
                maximumPlanes: 2
            )
        )
        let timestamp = HostTimestamp(
            ticks: AVAudioTime.hostTime(forSeconds: 1)
        )

        XCTAssertTrue(ring.write(buffer.audioBufferList, frameCount: 1, hostTime: timestamp))
        XCTAssertTrue(ring.write(buffer.audioBufferList, frameCount: 1, hostTime: timestamp))
        XCTAssertFalse(ring.write(buffer.audioBufferList, frameCount: 1, hostTime: timestamp))
        XCTAssertEqual(ring.takeOverflowCount(), 1)
        XCTAssertNotNil(ring.read())
        XCTAssertNotNil(ring.read())
        XCTAssertNil(ring.read())
    }

    func testBoundedHistoryEvictsByDurationAndByteLimit() async {
        let discarded = DiscardedAudioRecorder()
        let buffer = BoundedAudioBuffer(
            limits: .init(maximumDuration: 2, maximumBytes: 12),
            discardedChunkObserver: { discarded.record(.audio($0)) }
        )
        let first = makeChunk(at: 0, bytes: 4)
        let second = makeChunk(at: 1, bytes: 4)
        let third = makeChunk(at: 3.5, bytes: 8)

        let firstAppend = await buffer.append(first)
        let secondAppend = await buffer.append(second)
        let thirdAppend = await buffer.append(third)
        XCTAssertEqual(firstAppend, .stored)
        XCTAssertEqual(secondAppend, .stored)
        XCTAssertEqual(thirdAppend, .stored)

        let snapshot = await buffer.snapshot()
        let byteCount = await buffer.byteCount()
        XCTAssertEqual(snapshot, [third])
        XCTAssertEqual(byteCount, 8)
        XCTAssertEqual(discarded.audioEventCount(), 2)
        XCTAssertEqual(discarded.nonzeroAudioByteCount(), 0)

        await buffer.clear()
        let clearedSnapshot = await buffer.snapshot()
        let clearedByteCount = await buffer.byteCount()
        XCTAssertTrue(clearedSnapshot.isEmpty)
        XCTAssertEqual(clearedByteCount, 0)
        XCTAssertEqual(discarded.audioEventCount(), 3)
        XCTAssertEqual(discarded.nonzeroAudioByteCount(), 0)
    }

    func testBoundedHistoryRejectsSingleOversizedChunk() async {
        let buffer = BoundedAudioBuffer(
            limits: .init(maximumDuration: 60, maximumBytes: 3)
        )

        let appendResult = await buffer.append(makeChunk(at: 0, bytes: 4))
        let snapshot = await buffer.snapshot()
        XCTAssertEqual(appendResult, .rejectedTooLarge)
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testAudioChunkScrubOverwritesEveryOwnedByte() {
        var chunk = makeChunk(at: 0, bytes: 32)
        XCTAssertTrue(chunk.planes[0].data.contains { $0 != 0 })

        chunk.scrubAudioData()

        XCTAssertEqual(chunk.planes[0].data, Data(repeating: 0, count: 32))
    }

    func testSensitiveCaptureQueueBoundsAndScrubsDroppedAudio() async {
        let discarded = DiscardedAudioRecorder()
        let buffer = DiscardingAsyncStreamBuffer<AudioCaptureEvent>(
            maximumCount: 2,
            prepare: { $0.ownedForSensitiveBuffer() },
            discard: {
                $0.scrubAudioData()
                discarded.record($0)
            }
        )
        let stream = buffer.stream()

        XCTAssertEqual(buffer.yield(.audio(makeChunk(at: 0, bytes: 32))), .enqueued)
        XCTAssertEqual(buffer.yield(.audio(makeChunk(at: 1, bytes: 32))), .enqueued)
        XCTAssertEqual(buffer.yield(.audio(makeChunk(at: 2, bytes: 32))), .droppedOldest)
        XCTAssertEqual(buffer.queuedCount(), 2)
        XCTAssertEqual(buffer.discardedCount(), 1)
        XCTAssertEqual(discarded.nonzeroAudioByteCount(), 0)

        buffer.finish(delivering: .stopped(.output))
        XCTAssertEqual(buffer.queuedCount(), 1)
        XCTAssertEqual(buffer.discardedCount(), 3)
        XCTAssertEqual(discarded.audioEventCount(), 3)
        XCTAssertEqual(discarded.nonzeroAudioByteCount(), 0)

        var iterator = stream.makeAsyncIterator()
        let terminalEvent = await iterator.next()
        let endEvent = await iterator.next()
        XCTAssertEqual(terminalEvent, .stopped(.output))
        XCTAssertNil(endEvent)
        XCTAssertEqual(buffer.queuedCount(), 0)
    }

    func testSensitiveQueueFinishesWaitingContinuationWithoutRetainingValues() async {
        let buffer = DiscardingAsyncStreamBuffer<AudioCaptureEvent>(
            maximumCount: 2,
            prepare: { $0.ownedForSensitiveBuffer() },
            discard: { $0.scrubAudioData() }
        )
        let stream = buffer.stream()
        let eventTask = Task {
            var iterator = stream.makeAsyncIterator()
            let terminal = await iterator.next()
            let end = await iterator.next()
            return (terminal, end)
        }
        await Task.yield()

        buffer.finish(delivering: .stopped(.microphone))

        let result = await eventTask.value
        XCTAssertEqual(result.0, .stopped(.microphone))
        XCTAssertNil(result.1)
        XCTAssertEqual(buffer.queuedCount(), 0)
    }

    func testSensitiveQueueCanScrubFailedTeardownAttemptBeforeTerminalRetry() async {
        let discarded = DiscardedAudioRecorder()
        let buffer = DiscardingAsyncStreamBuffer<AudioCaptureEvent>(
            maximumCount: 2,
            prepare: { $0.ownedForSensitiveBuffer() },
            discard: {
                $0.scrubAudioData()
                discarded.record($0)
            }
        )
        let stream = buffer.stream()
        XCTAssertEqual(buffer.yield(.audio(makeChunk(at: 0, bytes: 32))), .enqueued)

        buffer.discardQueued()

        XCTAssertEqual(buffer.queuedCount(), 0)
        XCTAssertEqual(buffer.discardedCount(), 1)
        XCTAssertEqual(discarded.audioEventCount(), 1)
        XCTAssertEqual(discarded.nonzeroAudioByteCount(), 0)

        buffer.finish(delivering: .stopped(.output))
        var iterator = stream.makeAsyncIterator()
        let terminal = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(terminal, .stopped(.output))
        XCTAssertNil(end)
    }

    func testSealedRealtimeRingRejectsFurtherCallbackWrites() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
        )
        buffer.frameLength = 1
        let ring = RealtimeAudioRing(
            lane: .output,
            format: AudioFormatDescription(format),
            configuration: .init(slotCount: 2, maximumBytesPerSlot: 64, maximumPlanes: 2)
        )
        let timestamp = HostTimestamp(ticks: AVAudioTime.hostTime(forSeconds: 1))
        XCTAssertTrue(ring.write(buffer.audioBufferList, frameCount: 1, hostTime: timestamp))

        ring.sealAndClear()

        XCTAssertNil(ring.read())
        XCTAssertFalse(ring.write(buffer.audioBufferList, frameCount: 1, hostTime: timestamp))
        XCTAssertNil(ring.read())
    }

    func testAnalyzerInputQueueScrubsPCMOnSaturationAndFinish() throws {
        let first = try makeAnalyzerInput(sample: 0.75)
        let second = try makeAnalyzerInput(sample: -0.5)
        let buffer = DiscardingAsyncStreamBuffer<AnalyzerInput>(
            maximumCount: 1,
            discard: { AppleSpeechTranscriptionService.scrubAnalyzerInput(&$0) }
        )

        XCTAssertEqual(buffer.yield(first), .enqueued)
        XCTAssertEqual(buffer.yield(second), .droppedOldest)
        XCTAssertEqual(first.buffer.frameLength, 0)
        XCTAssertTrue(allSampleBytesAreZero(first.buffer))

        buffer.finish()
        XCTAssertEqual(second.buffer.frameLength, 0)
        XCTAssertTrue(allSampleBytesAreZero(second.buffer))
        XCTAssertEqual(buffer.queuedCount(), 0)
    }

    private func makeChunk(at seconds: TimeInterval, bytes: Int) -> CapturedAudioChunk {
        CapturedAudioChunk(
            lane: .output,
            hostTime: HostTimestamp(
                ticks: AVAudioTime.hostTime(forSeconds: seconds)
            ),
            frameCount: 16_000,
            format: AudioFormatDescription(
                sampleRate: 16_000,
                formatID: kAudioFormatLinearPCM,
                formatFlags: kAudioFormatFlagIsFloat,
                bytesPerPacket: 4,
                framesPerPacket: 1,
                bytesPerFrame: 4,
                channelsPerFrame: 1,
                bitsPerChannel: 32,
                isInterleaved: true
            ),
            planes: [CapturedAudioPlane(channelCount: 1, data: Data(repeating: 7, count: bytes))]
        )
    }

    private func makeAnalyzerInput(sample: Float) throws -> AnalyzerInput {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        buffer.frameLength = 4
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<4 { samples[index] = sample }
        return AnalyzerInput(buffer: buffer)
    }

    private func allSampleBytesAreZero(_ buffer: AVAudioPCMBuffer) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        return buffers.allSatisfy { audioBuffer in
            guard let data = audioBuffer.mData else { return true }
            let bytes = UnsafeRawBufferPointer(
                start: data,
                count: Int(audioBuffer.mDataByteSize)
            )
            return bytes.allSatisfy { $0 == 0 }
        }
    }
}

private final class DiscardedAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AudioCaptureEvent] = []

    func record(_ event: AudioCaptureEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func audioEventCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    func nonzeroAudioByteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.reduce(into: 0) { count, event in
            guard case .audio(let chunk) = event else { return }
            for plane in chunk.planes {
                count += plane.data.count(where: { $0 != 0 })
            }
        }
    }
}
