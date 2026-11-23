import CoreGraphics
import Testing

@testable import DesignSystemPhone

@Suite("Image sizes")
struct ImageSizeTests {

    @Test("A poster on a triple-scale device fits into one tier")
    func poster() {
        // 110 points × 3 = 330 pixels, rounded up to 400.
        #expect(ImageSizes.pixels(forItem: 110, reference: 3) == 400)
        // The same poster on a 2× device: 220 → 240.
        #expect(ImageSizes.pixels(forItem: 110, reference: 2) == 240)
    }

    /// The whole purpose of the rounding: three similar tile widths request **one** image size
    /// and not three. Otherwise the same poster lies in memory three times, and the server
    /// computes it three times.
    @Test("Similar edges land in the same tier")
    func bundles() {
        let slots = [110, 112, 118].map { ImageSizes.pixels(forItem: CGFloat($0), reference: 2) }
        #expect(Set(slots).count == 1)
    }

    @Test("The headroom is included")
    func headroom() {
        let without = ImageSizes.pixels(forItem: 200, reference: 2)
        let using = ImageSizes.pixels(forItem: 200, reference: 2, headroom: 1.2)
        #expect(using > without)
    }

    @Test("Request nothing for nothing")
    func nothing() {
        #expect(ImageSizes.pixels(forItem: 0, reference: 3) == 0)
    }
}
