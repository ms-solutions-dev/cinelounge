import Core
import Foundation
import Playback
import Testing

@testable import FeaturesPhone

/// What the picture fill may remember and what it may not.
///
/// **The costly error would not be remembering too little but too much.** A memory that
/// applies to all formats crops a 4:3 home video after a cinema film too —
/// and unnoticed, because what is missing is something the viewer never saw. These checks mainly
/// secure this one boundary.
@Suite("Picture fill")
struct PictureFillTests {

    /// A store of its own per test — otherwise one carries over into the next.
    @MainActor
    private static func fresh() -> PictureFill {
        PictureFill(store: InMemoryStore())
    }

    // MARK: - The default

    /// **Unknown means "whole picture", always.** The damage of an unnecessary bar is
    /// a bar; the damage of an unnecessary cut is a part of the picture that nobody
    /// misses because they never saw it.
    @Test("Without a stored choice the whole image shows")
    @MainActor
    func preset() {
        #expect(Self.fresh().state(forItem: 2.39) == .fullImage)
    }

    @Test("What was chosen is remembered")
    @MainActor
    func remembers() {
        let f = Self.fresh()
        f.set(.fillsScreen, forItem: 2.39)
        #expect(f.state(forItem: 2.39) == .fillsScreen)
    }

    // MARK: - The limit in question

    /// **The core of the type.** A filled cinema film must not crop a home video.
    @Test("A filled 21:9 leaves 4:3 untouched")
    @MainActor
    func fourThreeStaysWhole() {
        let f = Self.fresh()
        f.set(.fillsScreen, forItem: 2.39)
        #expect(f.state(forItem: 1.33) == .fullImage)
    }

    /// **2.35 and 2.39 are two spellings of the same cinema format.** Making two buckets of them
    /// would mean asking for the same decision twice — at the next film it
    /// would look as if the app had forgotten.
    @Test("The same cinema format is one bucket")
    @MainActor
    func cinemaFormatSingleFactor() {
        let f = Self.fresh()
        f.set(.fillsScreen, forItem: 2.35)
        #expect(f.state(forItem: 2.39) == .fillsScreen)
    }

    /// **16:9 and 4:3 are not** — otherwise the bucket would be so coarse that the boundary above
    /// no longer holds.
    @Test("Different formats are different buckets")
    @MainActor
    func differentMultiples() {
        #expect(PictureFill.bucket(1.78) != PictureFill.bucket(1.33))
    }

    /// **An engine that does not yet know a size reports 0.** Forming a bucket from it
    /// would mean overwriting the memory of a real format.
    @Test("Unusable values get no bucket", arguments: [0.0, -1.0, .infinity, 99.0])
    func notMultiple(_ value: Double) {
        #expect(PictureFill.bucket(value) == nil)
    }

    /// **The default is deleted and not written.** Otherwise the store would grow by
    /// every format that someone once watched and put back.
    @Test("Resetting cleans up")
    @MainActor
    func resetClearsOut() {
        let f = Self.fresh()
        f.set(.fillsScreen, forItem: 2.39)
        f.set(.fullImage, forItem: 2.39)
        #expect(f.state(forItem: 2.39) == .fullImage)
    }

    // MARK: - The arithmetic behind the gesture

    /// **The same in both directions.** A film wider than the screen lies with bars
    /// above and below, a narrower one with bars left and right — both times the
    /// factor is the ratio of the ratios.
    @Test("The fill factor applies in both directions")
    func factorBothDirections() {
        let wide = PictureFill.fillFactor(image: 2.4, screen: 2.0)
        let isNarrow = PictureFill.fillFactor(image: 2.0, screen: 2.4)
        #expect(abs(wide - 1.2) < 0.001)
        #expect(abs(isNarrow - 1.2) < 0.001)
    }

    /// **Without usable numbers the gesture moves nothing**, instead of scaling to
    /// infinity. That is the case of the direct renderer, which keeps no size.
    @Test("Without a format the factor is 1")
    func factorWithoutFormat() {
        #expect(PictureFill.fillFactor(image: 0, screen: 2.0) == 1)
        #expect(PictureFill.fillFactor(image: 2.0, screen: 0) == 1)
    }

    /// **Spreading fills — even with a short gesture** (on-device test, build 1332). 16:9 on
    /// a 19.5:9 screen has the factor 1.22; until 2026-09-27 the picture jumped back to
    /// the whole picture at six percent spread, because only the midpoint between the
    /// ends counted.
    @Test("Spreading fills, even if the fingers move apart only a little")
    func stretchFills() {
        #expect(
            PictureFill.snaps(magnification: 1.06, from: .fullImage, factor: 1.22)
                == .fillsScreen)
        #expect(
            PictureFill.snaps(magnification: 1.5, from: .fullImage, factor: 1.22)
                == .fillsScreen)
    }

    /// **Pinching together fits** — from the filled state the same short
    /// gesture in the other direction suffices.
    @Test("Pinching in fits the whole image")
    func pinchInFits() {
        #expect(
            PictureFill.snaps(magnification: 0.94, from: .fillsScreen, factor: 1.22)
                == .fullImage)
        #expect(
            PictureFill.snaps(magnification: 0.5, from: .fillsScreen, factor: 1.22)
                == .fullImage)
    }

    /// **Resting fingers switch nothing**, and a gesture in the direction that
    /// already applies leaves the state alone.
    @Test("Inside the dead zone the state stays")
    func deadZone() {
        #expect(
            PictureFill.snaps(magnification: 1.02, from: .fullImage, factor: 1.22) == .fullImage)
        #expect(
            PictureFill.snaps(magnification: 0.98, from: .fillsScreen, factor: 1.22)
                == .fillsScreen)
        #expect(
            PictureFill.snaps(magnification: 1.3, from: .fillsScreen, factor: 1.22)
                == .fillsScreen)
    }

    /// **If there is nothing to fill, nothing latches.** Otherwise a pinch on a picture
    /// that fits exactly would fix a state that changes nothing.
    @Test("Without gaining anything it stays at the whole image")
    func noSnapWithoutGain() {
        #expect(PictureFill.snaps(magnification: 1.5, from: .fullImage, factor: 1) == .fullImage)
    }

    /// The label names the state; the button shows the respective **other** one.
    @Test("Every state has its opposite")
    func oppositeState() {
        #expect(ImageLayout.fullImage.other == .fillsScreen)
        #expect(ImageLayout.fillsScreen.other == .fullImage)
    }
}
