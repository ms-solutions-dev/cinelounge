import AVFoundation
import Core
import CoreMedia
import Foundation
import Testing

@testable import Playback

/// The direct renderer — checked without a stream.
///
/// What can be checked here are the switch, the states and the startup rule. Whether
/// the hardware really draws is told only by the TV; the startup balance in the
/// report keeps the engine separately for that.
@MainActor
@Suite("The direct renderer")
struct RendererEngineTests {

    private func target(_ decision: PlaybackDecision) -> PlaybackTarget {
        PlaybackTarget(
            itemID: nil, title: "Test channel",
            url: URL(string: "http://127.0.0.1:1/sender.ts")!,
            decision: decision, kind: .live)
    }

    private var rendererDecision: PlaybackDecision {
        PlaybackDecision(engine: .renderer, delivery: .renderInApp, reason: .renderedInApp)
    }

    /// **The switch is the decision** — and the buffer its condition.
    @Test("The host builds the renderer when decision and buffer are there")
    func hostPicksRendererWithSamples() {
        let host = EngineHost()
        host.start(target(rendererDecision), samples: SampleQueue())

        #expect(host.engine == .renderer)
        #expect(host.isRunning)
        #expect(host.controller is SampleBufferPlaybackEngine)
        #expect(host.controller.status == .opening)
        #expect(host.report.contains("renderer"))
        host.stop()
    }

    /// A renderer without a buffer would have nothing to draw — then the system player
    /// plays, and the trace says the decision did not apply.
    @Test("Without a buffer the system player takes over")
    func hostFallsBackWithoutSamples() {
        let host = EngineHost()
        host.start(target(rendererDecision))

        #expect(host.engine == .native)
        #expect(host.controller is NativePlaybackEngine)
        host.stop()
    }

    @Test("A repackager target keeps getting the system player")
    func remuxTargetStaysNative() {
        let host = EngineHost()
        host.start(
            target(PlaybackDecision(engine: .native, delivery: .remuxInApp, reason: .remuxedInApp)),
            samples: SampleQueue())

        #expect(host.engine == .native)
        host.stop()
    }

    /// The startup rule: half a second of feed ahead of the clock.
    @Test("Starting happens from half a second of broadcast")
    func startRule() {
        let first = CMTime(seconds: 100, preferredTimescale: 90000)
        #expect(
            !SampleBufferPlaybackEngine.canStart(
                first: first, latest: CMTime(seconds: 100.4, preferredTimescale: 90000)))
        #expect(
            SampleBufferPlaybackEngine.canStart(
                first: first, latest: CMTime(seconds: 100.5, preferredTimescale: 90000)))
    }

    /// The states before the first frame — honest, not guessed.
    @Test("Before the first frame the engine says it has nothing")
    func statesBeforeFirstPicture() {
        let engine = SampleBufferPlaybackEngine(samples: SampleQueue())
        #expect(engine.status == .idle)
        #expect(engine.firstFrameVisible == nil)
        #expect(engine.hasVideoOutput == false)
        #expect(engine.droppedVideoFrames == nil)
        #expect(engine.readyToPlayAt == nil)

        engine.load(URL(string: "http://127.0.0.1:1/sender.ts")!, startingAt: 0)
        #expect(engine.status == .opening)
        #expect(engine.firstFrameVisible == false)
        #expect(engine.lead == nil)
        #expect(engine.duration == 0)
        #expect(engine.audioTracks.isEmpty)

        engine.stop()
        #expect(engine.status == .idle)
    }

    /// The supplied frame rate travels via the host into the renderer.
    @Test("The frame rate reaches the renderer through the host")
    func frameRateReachesRenderer() {
        let host = EngineHost()
        host.start(target(rendererDecision), samples: SampleQueue())
        host.adopt(contentFrameRate: 50)

        #expect((host.controller as? SampleBufferPlaybackEngine)?.contentFrameRate == 50)
        host.stop()
    }
}

/// The span of the audio offset as a sentence in the balance.
@Suite("The audio offset as a sentence")
struct SkewTextTests {

    @Test("Audio behind the picture")
    func behind() {
        #expect(SampleBufferPlaybackEngine.skewText((-0.6)...(-0.2)) == "Audio 0.2–0.6 s behind the picture")
    }

    @Test("Audio ahead of the picture")
    func ahead() {
        #expect(SampleBufferPlaybackEngine.skewText(0.1...0.4) == "Audio 0.1–0.4 s ahead of the picture")
    }

    @Test("Audio around the picture")
    func around() {
        #expect(
            SampleBufferPlaybackEngine.skewText((-0.3)...0.1)
                == "Audio 0.3 s behind to 0.1 s ahead of the picture")
    }
}

/// Recognize the rejection of the partial path — in the error or beneath it.
@Suite("The rejection of the partial route")
struct LowLatencyRejectionTests {
    @Test("-15410 counts below it, another error does not")
    func detectsUnderlyingCode() {
        let inner = NSError(domain: "CoreMediaErrorDomain", code: -15410)
        let outer = NSError(
            domain: "AVFoundationErrorDomain", code: -11855, userInfo: [NSUnderlyingErrorKey: inner])
        #expect(NativePlaybackEngine.isLowLatencyRejection(outer))
        #expect(
            !NativePlaybackEngine.isLowLatencyRejection(
                NSError(domain: "AVFoundationErrorDomain", code: -11800)))
        #expect(!NativePlaybackEngine.isLowLatencyRejection(nil))
    }
}

/// The entry for the system display.
@Suite("Now Playing")
struct NowPlayingInfoTests {
    @Test("A channel is a live stream without duration, a movie has its duration")
    func liveAndFilm() {
        let live = NowPlayingBridge.info(
            title: "TELVE 1", subtitle: "TR", isLive: true, position: 12, duration: 0, isPlaying: true)
        #expect(live["title"] as? String == "TELVE 1")
        #expect(live["MPNowPlayingInfoPropertyIsLiveStream"] as? Bool == true)
        #expect(live["playbackDuration"] == nil)
        #expect(live["MPNowPlayingInfoPropertyPlaybackRate"] as? Double == 1.0)

        let film = NowPlayingBridge.info(
            title: "Quinte", subtitle: nil, isLive: false, position: 600, duration: 7200, isPlaying: false)
        #expect(film["playbackDuration"] as? TimeInterval == 7200)
        #expect(film["MPNowPlayingInfoPropertyElapsedPlaybackTime"] as? TimeInterval == 600)
        #expect(film["MPNowPlayingInfoPropertyPlaybackRate"] as? Double == 0.0)
        #expect(film["artist"] == nil)
    }
}
