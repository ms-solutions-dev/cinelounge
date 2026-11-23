import CoreMedia
import Foundation
import Testing

@testable import Core

/// The own decoder — the same hardware, own rules.
@Suite("The own decoder")
struct HardwareVideoDecoderTests {

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [CMTime] = []
        private var widths: [Int32] = []
        func add(_ sample: CMSampleBuffer) {
            lock.lock()
            defer { lock.unlock() }
            times.append(sample.presentationTimeStamp)
            if let image = sample.imageBuffer { widths.append(Int32(CVPixelBufferGetWidth(image))) }
        }
        var all: [CMTime] {
            lock.lock()
            defer { lock.unlock() }
            return times
        }
        var sizes: [Int32] {
            lock.lock()
            defer { lock.unlock() }
            return widths
        }
    }

    /// Without a description there is nothing to decode — the caller passes it through.
    @Test("A packet without a description is rejected, not swallowed")
    func rejectsSampleWithoutFormat() throws {
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer)
        let decoder = HardwareVideoDecoder { _ in }
        #expect(!decoder.decode(try #require(buffer)))
    }
}
