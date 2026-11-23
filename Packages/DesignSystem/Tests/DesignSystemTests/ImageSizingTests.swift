import CoreGraphics
import Testing

@testable import DesignSystem

/// This computes what previously stood as a number at the call sites — and the
/// numbers were off. Pinned down are therefore the two directions in which
/// that takes revenge: fetched too large costs memory and computing time, fetched too small is
/// visible on the TV as blur.
@Suite("Image sizes")
struct ImageSizingTests {

    @Test("The device scale is included — a poster of 240 points needs more than 240")
    func scaleIsApplied() {
        let width = ImageSizing.requestWidth(points: 240, headroom: 1)
        // 240 points × scale 2 = 480 pixels.
        #expect(width >= 480)
        // And not more than one rounding step above.
        #expect(width < 480 + Int(ImageSizing.step))
    }

    @Test("The focus allowance is included")
    func focusHeadroom() {
        let resting = ImageSizing.requestWidth(points: 240, headroom: 1)
        let growing = ImageSizing.requestWidth(points: 240)
        #expect(growing > resting, "a card grows when focused and needs more pixels there")
    }

    @Test("Rounding goes up, never down")
    func roundsUp() {
        // Rounding down would mean fetching an image smaller than it is drawn — that is the
        // visible error. That is why the direction is pinned down.
        for points in stride(from: CGFloat(10), through: 600, by: 7) {
            let needed = points * ImageSizing.drawScale
            #expect(CGFloat(ImageSizing.requestWidth(points: points, headroom: 1)) >= needed)
        }
    }

    @Test("Rounding merges nearby sizes")
    func nearbySizesShareOneWidth() {
        // What the rounding is there for in the first place: two call sites that have almost the same
        // measure should share one entry in the cache, instead of fetching the same
        // file twice and decoding it twice.
        #expect(ImageSizing.requestWidth(points: 240) == ImageSizing.requestWidth(points: 250))

        // It does not merge arbitrarily far, though — otherwise a large image would be fetched for a small
        // surface. 240 and 260 points already lie apart,
        // and **that is why** grid tile and info column explicitly name
        // the same measure instead of relying on the rounding.
        #expect(ImageSizing.requestWidth(points: 240) != ImageSizing.requestWidth(points: 260))
    }

    @Test("Backdrops are capped")
    func backdropIsCapped() {
        // Fully computed it would be 3840 pixels and 26 MB per image; the header
        // pages through up to eight titles.
        #expect(ImageSizing.backdropWidth(points: 1920) == ImageSizing.backdropCeiling)
    }

    @Test("The cap is a memory calculation, not a sharpness calculation")
    func backdropCeilingFitsInMemory() {
        // **Here once stood the demand that the cap must lie ABOVE 1920** — with
        // the reasoning that previously too little had been requested. That was true for
        // sharpness and wrong for memory: at 2560 a background image takes up
        // 14.7 MB decoded, and eight header candidates fill 118 MB
        // of 160. The rest no longer suffices for the posters — the cache
        // evicts what is currently visible, and images disappear again.
        //
        // That is why this computes instead of demanding: eight background images must
        // not take up more than half of the memory.
        let bytesPerBackdrop =
            Double(ImageSizing.backdropCeiling)
            * Double(ImageSizing.backdropCeiling) * 9 / 16 * 4
        let eight = 8 * bytesPerBackdrop

        #expect(
            eight <= 80 * 1024 * 1024,
            "eight backdrops take \(Int(eight / 1024 / 1024)) MB — too much"
        )
    }

    @Test("A small surface is not capped but calculated")
    func smallAreaIsNotCapped() {
        #expect(ImageSizing.backdropWidth(points: 400) == 800)
    }

    @Test("The decode limit takes the longer edge")
    func decodeLimitUsesLongerEdge() {
        // ImageIO takes only one number. For a poster in 2:3 format that is the height —
        // whoever takes the width downscales the image a third too far.
        let poster = ImageSizing.decodeLimit(points: CGSize(width: 240, height: 360), headroom: 1)
        #expect(poster >= 720)

        let wide = ImageSizing.decodeLimit(points: CGSize(width: 420, height: 236), headroom: 1)
        #expect(wide >= 840)
    }

    @Test("A surface without extent does not yield a size of zero")
    func zeroIsNotZero() {
        // Otherwise a view whose size is not yet known requests an image of
        // zero pixels — and gets nothing, without any error occurring.
        #expect(ImageSizing.requestWidth(points: 0) > 0)
        #expect(ImageSizing.decodeLimit(points: .zero) > 0)
    }
}
