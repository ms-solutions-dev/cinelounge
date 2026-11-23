import CoreGraphics

#if canImport(UIKit)
    import UIKit
#endif

/// From points to pixels.
///
/// On the TV that is a 2, fixed. On the phone it is **2 or 3 per device** — if that is
/// assumed wrongly, the app loads either blurry images or one and a half times the data.
/// Through a tunnel with a measured 0.31 Mbit/s that is no difference of finesse.
///
/// The value is read from the environment, not guessed.
public enum ImageSizes {

    /// The edge length is rounded up to this many pixels.
    ///
    /// Without this rounding every tile width requests an image size of its own — a detail page
    /// with 110, 112 and 118 points would have three versions of the same poster in memory, and
    /// the server calculates them three times. Eighty is coarse enough to bundle and fine enough
    /// that nothing is visibly loaded too large.
    public static let tier = 80

    /// The drawing scale of this device.
    @MainActor
    public static var reference: CGFloat {
        #if canImport(UIKit)
            UITraitCollection.current.displayScale
        #else
            2
        #endif
    }

    /// How many pixels to request for an edge in points.
    ///
    /// - Parameters:
    ///   - punkte: the edge as it stands on screen
    ///   - massstab: 2 or 3
    ///   - kopfraum: allowance for tiles that grow when pressed
    public static func pixels(
        forItem points: CGFloat, reference: CGFloat, headroom: CGFloat = 1
    ) -> Int {
        let raw = points * reference * headroom
        guard raw > 0 else { return 0 }
        return Int((raw / CGFloat(tier)).rounded(.up)) * tier
    }
}
