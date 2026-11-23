import CoreMedia
import Foundation
import Testing

@testable import Core

/// A picture without content but with time — for the calculations of the buffer that
/// is enough: it counts and measures, it does not decode.
private func probe(_ seconds: Double, decode: Double? = nil) throws -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 25),
        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 90000),
        decodeTimeStamp: decode.map { CMTime(seconds: $0, preferredTimescale: 90000) } ?? .invalid
    )
    var buffer: CMSampleBuffer?
    let status = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
        sampleCount: 0, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer)
    try #require(status == noErr)
    return try #require(buffer)
}

/// The buffer from which the direct renderer is served.
@Suite("The direct renderer's sample queue")
struct SampleQueueTests {

    @Test("What goes in comes out in the same order")
    func roundTripKeepsOrder() throws {
        let queue = SampleQueue()
        queue.append(video: try probe(1.0))
        queue.append(video: try probe(1.04))
        queue.append(audio: try probe(1.0))

        #expect(queue.receivedVideo == 2)
        #expect(queue.receivedAudio == 1)
        #expect(queue.pendingVideoCount == 2)
        #expect(queue.nextVideo()?.presentationTimeStamp.seconds == 1.0)
        #expect(queue.nextVideo()?.presentationTimeStamp.seconds == 1.04)
        #expect(queue.nextVideo() == nil)
        #expect(queue.nextAudio() != nil)
        #expect(queue.nextAudio() == nil)
    }

    /// **The number the session waits for.** It measures from the next waiting picture
    /// to the most recent delivered one — not from the first ever delivered, otherwise it
    /// would grow with every second of playback.
    @Test("The queue measures what is still waiting")
    func bufferedSecondsCountOnlyWhatWaits() throws {
        let queue = SampleQueue()
        #expect(queue.bufferedSeconds == 0)

        for step in 0..<26 { queue.append(video: try probe(10 + Double(step) * 0.04)) }
        #expect(abs(queue.bufferedSeconds - 1.0) < 0.001)
        #expect(queue.firstVideoTime?.seconds == 10)
        #expect(abs((queue.latestVideoTime?.seconds ?? 0) - 11) < 0.001)

        // Half collected: only the other half is still waiting.
        for _ in 0..<13 { _ = queue.nextVideo() }
        #expect(abs(queue.bufferedSeconds - 0.48) < 0.001)
        #expect(abs((queue.firstPendingVideoTime?.seconds ?? 0) - 10.52) < 0.001)
    }

    /// **With B-frames the presentation time jumps back.** That is why it is measured by
    /// the decoding time — which rises strictly, the remuxer takes care of that.
    @Test("Measuring uses the decode time where there is one")
    func ordersByDecodeTime() throws {
        let queue = SampleQueue()
        queue.append(video: try probe(1.08, decode: 1.00))
        queue.append(video: try probe(1.00, decode: 1.04))
        queue.append(video: try probe(1.04, decode: 1.08))

        #expect(queue.firstVideoTime?.seconds == 1.00)
        #expect(abs((queue.latestVideoTime?.seconds ?? 0) - 1.08) < 0.001)
        #expect(abs(queue.bufferedSeconds - 0.08) < 0.001)
    }

    /// **An engine that does not take frames must not fill the memory.** The oldest goes
    /// — what would be played next is the youngest.
    @Test("A stalled consumer lets the oldest sample drop")
    func overflowDropsOldest() throws {
        let queue = SampleQueue()
        for step in 0...SampleQueue.maximumFrames {
            queue.append(video: try probe(Double(step) * 0.04))
        }

        #expect(queue.pendingVideoCount == SampleQueue.maximumFrames)
        #expect(queue.discarded == 1)
        // The first is gone, the second is now at the front.
        #expect(abs((queue.nextVideo()?.presentationTimeStamp.seconds ?? -1) - 0.04) < 0.001)
    }

    /// Without the wake-up call the renderer would stay silent after the first idle.
    @Test("Every new packet wakes the consumer")
    func appendWakesTheConsumer() async throws {
        let queue = SampleQueue()
        let counter = CounterBox()
        queue.onAvailable = { counter.increment() }

        queue.append(video: try probe(1))
        queue.append(audio: try probe(1))
        await queue.finish()

        #expect(counter.value == 3)
        #expect(queue.isFinished)
    }

    /// The frame rate for registration with the TV — from the distances between the
    /// pictures, not from an assertion.
    @Test("The queue measures the frame cadence")
    func measuresFrameRate() throws {
        let queue = SampleQueue()
        #expect(queue.frameRate == nil)
        for step in 0..<40 { queue.append(video: try probe(Double(step) * 0.04)) }
        let rate = try #require(queue.frameRate)
        #expect(abs(rate - 25) < 0.5)
    }

    @Test("Drain throws away everything waiting")
    func drainEmpties() throws {
        let queue = SampleQueue()
        queue.append(video: try probe(1))
        queue.append(audio: try probe(1))
        queue.drain()
        #expect(queue.pendingVideoCount == 0)
        #expect(queue.pendingAudioCount == 0)
        // But the count stays — it is the balance.
        #expect(queue.receivedVideo == 1)
    }

    /// A counter that a `@Sendable` closure may increment.
    private final class CounterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        func increment() {
            lock.lock()
            defer { lock.unlock() }
            _value += 1
        }
    }
}

/// **The same remuxer, a different output.** What arrives here must be the same as
/// what would otherwise go into the writer — only without a container.
@Suite("The remuxer fills the renderer's queue")
struct RemuxerToQueueTests {

    private func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts"))
        return try Data(contentsOf: url)
    }
}

/// The live session with the renderer as output — the same bracket, without the
/// server and list behind it.
@Suite("A channel from the network into the queue")
struct LiveRendererSessionTests {

    private func provider() throws -> LocalMediaServer {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts"))
        let data = try Data(contentsOf: url)
        let server = try LocalMediaServer()
        server.provider = { name in name == "sender.ts" ? (data, "video/mp2t") : nil }
        return server
    }

    /// The startup rule of the renderer knows no segments — only airtime.
    @Test("The renderer starts up by airtime, not by pieces")
    func rendererReadinessIsSecondsOnly() {
        #expect(LiveRemuxSession.rendererHasEnough(seconds: 1.0, wanted: 1.0))
        #expect(!LiveRemuxSession.rendererHasEnough(seconds: 0.9, wanted: 1.0))
        #expect(LiveRemuxSession.defaultRendererReadySeconds < LiveRemuxSession.defaultReadySeconds)
    }
}

/// The switch between the live engines and the redirection of the decision.
@Suite("The choice of the live engine")
struct LiveEngineChoiceTests {

    @Test("The default is the HLS path, and it is not written")
    func defaultIsNotStored() {
        let store = InMemoryStore()
        #expect(LiveEngineChoice.load(from: store) == .hls)

        LiveEngineChoice.renderer.save(to: store)
        #expect(LiveEngineChoice.load(from: store) == .renderer)

        LiveEngineChoice.hls.save(to: store)
        #expect(LiveEngineChoice.load(from: store) == .hls)
        #expect((try? store.value(for: LiveEngineChoice.storageKey)) == nil)
    }

    @Test("Only a remuxer target is redirected to the renderer")
    func onlyRemuxTargetsAreRedirected() {
        let remux = PlaybackDecision(engine: .native, delivery: .remuxInApp, reason: .remuxedInApp)
        let direct = PlaybackDecision(engine: .native, delivery: .directPlay, reason: .nativeContainer)

        let renderer = remux.asRenderer()
        #expect(renderer.engine == .renderer)
        #expect(renderer.delivery == .renderInApp)
        #expect(renderer.reason == .renderedInApp)
        #expect(renderer.runsOverRepacker)
        #expect(remux.runsOverRepacker)
        #expect(direct.asRenderer() == direct)
        #expect(!direct.runsOverRepacker)
    }

    @Test("The way back for the preview leads to the HLS path")
    func previewGetsHLSBack() {
        let remux = PlaybackDecision(
            engine: .native, delivery: .remuxInApp, reason: .remuxedInApp, maxBitrate: 5_000_000)
        let reconnectCount = remux.asRenderer().asRepacker()
        #expect(reconnectCount == remux)
    }
}

/// The audio track choice for channels — language from the table, switch in the
/// remuxer.
@Suite("The audio track choice on channels")
struct AudioChoiceTests {

    /// An ISO 639 descriptor as it stands in the program table.
    private func language(_ code: String) -> Data {
        var d = Data([0x0A, 0x04])
        d.append(Data(code.utf8))
        d.append(0)  // Art: Original
        return d
    }

    @Test("The language is read from the descriptor")
    func languageFromDescriptor() {
        #expect(TransportStream.language(in: language("deu")) == "deu")
        // A foreign descriptor in front does not matter.
        var mixed = Data([0x52, 0x01, 0x07])
        mixed.append(language("tur"))
        #expect(TransportStream.language(in: mixed) == "tur")
        #expect(TransportStream.language(in: Data()) == nil)
        #expect(TransportStream.language(in: Data([0x0A, 0x01, 0x41])) == nil)
    }

    @Test("The table names the audio streams with their language")
    func inventoryListsAudioStreams() {
        let streams = [
            TransportStream.Elementary(pid: 0x100, kind: .hevc),
            TransportStream.Elementary(pid: 0x101, kind: .mp2Audio, language: "tur"),
            TransportStream.Elementary(pid: 0x102, kind: .mp2Audio, language: "eng"),
            TransportStream.Elementary(pid: 0x103, kind: .other(0x06)),
        ]
        let inventory = TransportStream.Inventory(streams: streams)
        #expect(inventory.audioStreams.map(\.pid) == [0x101, 0x102])
        #expect(inventory.audioStreams.map(\.language) == ["tur", "eng"])
    }

    /// The switch throws away the waiting audio and leaves the picture alone.
    @Test("A switch empties the waiting audio, not the picture")
    func switchDropsPendingAudio() throws {
        let queue = SampleQueue()
        queue.append(video: try probe(1))
        queue.append(audio: try probe(1))
        queue.append(audio: try probe(1.02))
        queue.audioTrackChanged()

        #expect(queue.pendingAudioCount == 0)
        #expect(queue.pendingVideoCount == 1)
        #expect(queue.audioSwitches == 1)
        #expect(queue.audioFormat == nil)
    }
}

/// Where the audio arrives relative to the picture — the number for Pusula 1 (F-016).
@Suite("The audio gap in the queue")
struct AudioSkewTests {

    @Test("Without a picture there is no gap")
    func noVideoNoSkew() throws {
        let queue = SampleQueue()
        queue.append(audio: try probe(1.0))
        #expect(queue.audioSkew == nil)
    }

    @Test("The range keeps the smallest and largest gap")
    func rangeTracksMinAndMax() throws {
        let queue = SampleQueue()
        queue.append(video: try probe(1.0))
        queue.append(audio: try probe(0.7))  // 0,3 s hinter dem Bild
        queue.append(video: try probe(1.04))
        queue.append(audio: try probe(1.14))  // 0,1 s davor
        let span = try #require(queue.audioSkew)
        #expect(abs(span.lowerBound + 0.3) < 0.001)
        #expect(abs(span.upperBound - 0.1) < 0.001)
    }
}
