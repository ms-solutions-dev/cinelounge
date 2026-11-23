import CoreGraphics
import Foundation

/// How large an image is requested and how large it is decoded.
///
/// **Why this lives in one place.** Previously the call sites carried their widths
/// as bare numbers: 840 for a poster of 240 points, 1920 for a header
/// of 1920 points. The first was too large, the second too small — and neither was
/// recognizable from the number, because nowhere did it say what it refers to. Anyone who
/// names the display size instead of a pixel count can no longer miscalculate.
public enum ImageSizing {

    /// The scale at which tvOS **draws** — not the one at which it lays out.
    ///
    /// Layout is in 1920×1080 points, drawing on an Apple TV 4K is at
    /// 3840×2160 pixels. **Measured and not assumed:** a screenshot
    /// of the simulator (`xcrun simctl io … screenshot`) is 3840×2160.
    ///
    /// That is the difference on which two comments in this project
    /// contradicted each other — and it decides the whole memory budget: a poster of
    /// 240×360 points, decoded, takes up not 345 kilobytes but **1.38 MB**.
    ///
    /// As a fixed number and not queried from the device: the addresses are built
    /// at places with no actor context, and `UIScreen` belongs to the main actor.
    /// An Apple TV HD draws at 1 — so something slightly too large is fetched there, which is
    /// scaled down again on decoding anyway. The opposite mistake would be
    /// visible, this one is not.
    public static let drawScale: CGFloat = 2

    /// Surcharge for the enlargement in focus.
    ///
    /// A card grows to ``Tokens/Focus/cardScale``. Without a surcharge exactly the
    /// resting size is fetched, and in focus — that is, whenever someone is looking — the
    /// image is upscaled by twelve percent.
    public static let focusHeadroom: CGFloat = Tokens.Focus.cardScale

    /// Rounds up to this multiple.
    ///
    /// **So that not every call site creates its own cache entry.**
    /// 240 and 260 points of display width would otherwise give 538 and 583 pixels, that is two
    /// addresses, two fetches and two decoded images for the same poster. Rounded,
    /// both coincide at 600.
    static let step: CGFloat = 40

    /// The width requested from the server — in pixels.
    ///
    /// - Parameters:
    ///   - points: The width at which the image is **drawn**, in points.
    ///   - headroom: Surcharge for the enlargement in focus. For surfaces that do not
    ///     enlarge — header, background image of a detail page — 1 belongs
    ///     here, otherwise a full-screen image is fetched twelve percent larger yet again.
    public static func requestWidth(points: CGFloat, headroom: CGFloat = focusHeadroom) -> Int {
        Int(rounded(points * drawScale * headroom))
    }

    /// Upper limit for full-screen background images, in pixels.
    ///
    /// **This deliberately stays below the device's scale.** Fully computed it
    /// would be 3840 pixels, **26 MB** decoded — and the header pages
    /// through up to eight titles, so more than 200 MB for the images alone.
    ///
    /// 2560 is the compromise: an enlargement by a factor of 1.5, which is not noticeable behind the
    /// gradients and the text of the header, at 12 MB per image.
    /// Previously 1920 was fetched and thus scaled up to double — **that**
    /// was visible on the TV.
    ///
    /// Applies only to surfaces of screen size. A poster is not capped; there
    /// sharpness counts, and it costs little.
    /// **1920 and not 2560, and the number is a memory calculation.**
    ///
    /// A background image at 2560 pixels width takes up 14.7 MB decoded. The
    /// Home screen holds eight candidates for the header — anyone who pages through once
    /// has 118 MB of them in memory, with an upper limit of 160. The rest then does
    /// not suffice for the posters, and the cache evicts what is currently
    /// visible. That is exactly what shows as "images are not always there": they were there,
    /// and a background image displaced them.
    ///
    /// At 1920 it is 8.3 MB. The difference is not visible: the header lies
    /// behind two opaque gradients, and the image is drawn at screen width
    /// anyway.
    public static let backdropCeiling = 1920

    /// The width for a full-screen background image, capped.
    ///
    /// Without a focus surcharge: a surface of screen size does not grow.
    public static func backdropWidth(points: CGFloat) -> Int {
        min(requestWidth(points: points, headroom: 1), backdropCeiling)
    }

    /// The longest edge to which decoding downscales — in pixels.
    ///
    /// **The safeguard against everything that goes wrong above.** The server may
    /// ignore `maxWidth`, a channel list delivers its logo at whatever size it has, and an
    /// address from the cache may come from a version with different
    /// numbers. If decoding downscales to the size at which it is drawn,
    /// the memory calculation is right regardless.
    ///
    /// The **longest** edge, because ImageIO takes only one number: the ratio is
    /// preserved, and a poster in 2:3 format is limited by its height.
    public static func decodeLimit(
        points: CGSize,
        headroom: CGFloat = focusHeadroom
    ) -> Int {
        Int(rounded(max(points.width, points.height) * drawScale * headroom))
    }

    /// Rounds **up** to a multiple of ``step`` — never down.
    ///
    /// Rounding down would mean fetching an image smaller than it is drawn; that is the
    /// visible error. Rounding up costs pixels that nobody sees.
    static func rounded(_ value: CGFloat) -> CGFloat {
        guard value > 0 else { return step }
        return (value / step).rounded(.up) * step
    }
}
