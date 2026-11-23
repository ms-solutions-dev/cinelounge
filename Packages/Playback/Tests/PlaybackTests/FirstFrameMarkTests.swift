import AVFoundation
import Core
import Foundation
import Testing

@testable import Playback

/// The honest frame mark — "visible" instead of "announced" (roadmap AP5).
///
/// The occasion: with the system player `presentationSize` is already set when it has
/// merely read the format descriptions. The startup measurement called that "first
/// frame" and was thereby half blind — every speed change would have looked like
/// progress or regression without the number being worth anything. Only the video
/// layer attests the real drawing (`isReadyForDisplay`); the rules for it are in
/// ``NativePlaybackEngine/firstFrameVerdict`` and are pinned down here branch by
/// branch.
@MainActor
@Suite("The honest first-frame mark")
struct FirstFrameMarkTests {

    private var url: URL {
        URL(fileURLWithPath: "/tmp/cinelounge-nicht-vorhanden.mp4")
    }

    // MARK: - The rule, branch by branch

    @Test("Without a target there is no answer")
    func verdictNeedsAnItem() {
        // `nil` and not `false`: an empty engine is not blind, it simply has nothing to
        // show.
        #expect(
            NativePlaybackEngine.firstFrameVerdict(
                hasItem: false,
                externalPlayback: false,
                presentationSizeKnown: false,
                layerAttached: true,
                layerReady: true
            ) == nil
        )
    }

    @Test("On AirPlay the frame size counts, not the local layer")
    func verdictTrustsPresentationSizeOnAirPlay() {
        // The picture arises on the other device; the layer here stays empty forever.
        // Whoever asked it anyway would report "no picture" for every AirPlay playback
        // forever — and the measurement would give up after thirty seconds for no reason.
        #expect(
            NativePlaybackEngine.firstFrameVerdict(
                hasItem: true,
                externalPlayback: true,
                presentationSizeKnown: true,
                layerAttached: true,
                layerReady: false
            ) == true
        )
        #expect(
            NativePlaybackEngine.firstFrameVerdict(
                hasItem: true,
                externalPlayback: true,
                presentationSizeKnown: false,
                layerAttached: false,
                layerReady: false
            ) == false
        )
    }

    @Test("Without a layer there is no honest answer")
    func verdictNeedsALayer() {
        // The state of the checks on the Mac — and the moment between engine switch and
        // rebuild of the surface. A guessed answer would be worse than none: exactly from
        // such a one arose the half blindness that is abolished here.
        #expect(
            NativePlaybackEngine.firstFrameVerdict(
                hasItem: true,
                externalPlayback: false,
                presentationSizeKnown: true,
                layerAttached: false,
                layerReady: false
            ) == nil
        )
    }

    @Test("The known frame size alone does not set the mark")
    func verdictIgnoresAnnouncedSize() {
        // The core of the finding: metadata read does not mean frame drawn.
        #expect(
            NativePlaybackEngine.firstFrameVerdict(
                hasItem: true,
                externalPlayback: false,
                presentationSizeKnown: true,
                layerAttached: true,
                layerReady: false
            ) == false
        )
    }

    @Test("Only the drawn layer makes the picture visible")
    func verdictTrustsTheLayer() {
        #expect(
            NativePlaybackEngine.firstFrameVerdict(
                hasItem: true,
                externalPlayback: false,
                presentationSizeKnown: false,
                layerAttached: true,
                layerReady: true
            ) == true
        )
    }

    // MARK: - The engine as a whole

    @Test("Without a target and without a layer: no answer")
    func engineStartsWithoutVerdict() {
        let engine = NativePlaybackEngine()
        #expect(engine.firstFrameVisible == nil)

        engine.load(url, startingAt: 0)
        // Target there, but no surface attached — still no information.
        #expect(engine.firstFrameVisible == nil)
    }

    @Test("With a layer attached, not knowing becomes an honest no")
    func attachingALayerEnablesTheVerdict() {
        let engine = NativePlaybackEngine()
        engine.load(url, startingAt: 0)

        let layer = AVPlayerLayer()
        engine.attachDisplayLayer(layer)

        // The layer has never drawn — that is now an answer, not a gap.
        #expect(engine.firstFrameVisible == false)
    }

    @Test("A new target resets the mark")
    func loadResetsTheMark() {
        // On a target change the layer still shows the last frame of the previous film; its
        // own reset comes asynchronously. Without the reset in load, the new target's mark
        // would already stand on opening — the same lie as before, just from a different
        // source.
        let engine = NativePlaybackEngine()
        let layer = AVPlayerLayer()
        engine.attachDisplayLayer(layer)
        engine.layerReadyForDisplay = true

        engine.load(url, startingAt: 0)

        #expect(engine.firstFrameVisible == false)
    }

    @Test("The same layer is attached only once")
    func attachIsIdempotent() {
        // The surface calls the attaching on every SwiftUI pass. If the observation were set
        // up anew each time, a bunch of observers would end up hanging on the same layer —
        // and the remembered state would be overwritten by the layer's initial state.
        let engine = NativePlaybackEngine()
        let layer = AVPlayerLayer()
        engine.attachDisplayLayer(layer)
        engine.layerReadyForDisplay = true

        engine.attachDisplayLayer(layer)

        #expect(engine.layerReadyForDisplay, "attaching again does not throw the state away")
    }

    // MARK: - The ready mark

    @Test("A new target also resets the ready mark")
    func loadResetsTheReadinessMark() {
        // A new target measures anew — that applies to readiness just as to the frame mark,
        // regardless of whether the host builds a fresh engine per target anyway.
        let engine = NativePlaybackEngine()
        engine.readyToPlayAt = Date()

        engine.load(url, startingAt: 0)

        #expect(engine.readyToPlayAt == nil)
    }

    @Test("The stopped engine no longer carries a ready mark")
    func stopClearsTheReadinessMark() {
        // In the remuxer path several seconds lie between `stop()` and the start of the new
        // engine, and the host keeps handing out this object until then. A leftover mark
        // would be that of the previous channel in this gap.
        let engine = NativePlaybackEngine()
        engine.load(url, startingAt: 0)
        engine.readyToPlayAt = Date()

        engine.stop()

        #expect(engine.readyToPlayAt == nil)
    }
}
