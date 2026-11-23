import CoreMedia
import Foundation
import Testing

@testable import Core

/// **Cap in bytes, not only in packets** (AP73, 2026-10-11): a UHD picture weighs ten
/// times an SD picture; the same packet cap let the memory grow ten times as far.
@Suite("Buffer cap (AP73)")
struct BufferCapTests {

    @Test("The queue trims at the front as soon as count or bytes overflow")
    func trimsByBoth() {
        var queue = CappedQueue<Int>(cap: BufferCap(count: 3, bytes: 10)) { $0 }
        #expect(queue.append(4) == 0)
        #expect(queue.append(4) == 0)
        // 12 bytes with three packets: the bytes break first, the oldest flies out.
        #expect(queue.append(4) == 1)
        #expect(queue.count == 2)
        #expect(queue.bytes == 8)
        // Four small packets: now the count breaks.
        #expect(queue.append(1) == 0)
        #expect(queue.append(1) == 1)
        #expect(queue.count == 3)
        #expect(queue.bytes == 6)
        // A single giant packet stays — the queue is never completely empty.
        queue.removeAll()
        #expect(queue.append(99) == 0)
        #expect(queue.count == 1)
        _ = queue.removeFirst()
        #expect(queue.bytes == 0)
    }

    @Test("The direct renderer's queue also caps in bytes")
    func downloadsInBytes() throws {
        let queue = SampleQueue()
        let megabyte = 1 << 20
        let pieces = SampleQueue.maximumFrameBytes / megabyte + 6
        for step in 0..<pieces {
            queue.append(video: try Self.heavy(Double(step) * 0.04, bytes: megabyte))
        }
        #expect(queue.pendingVideoCount == SampleQueue.maximumFrameBytes / megabyte)
        #expect(queue.discarded == 6)
        #expect(queue.pendingVideoCount < SampleQueue.maximumFrames)
    }

    /// A picture with time **and** weight — the payload is an empty block.
    static func heavy(_ seconds: Double, bytes: Int) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        try #require(blockStatus == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 25),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 90000),
            decodeTimeStamp: .invalid)
        var size = bytes
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
        try #require(status == noErr)
        let sample = try #require(buffer)
        #expect(BufferCap.size(sample) == bytes)
        return sample
    }
}
