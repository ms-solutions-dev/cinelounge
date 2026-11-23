import Core
import CoreGraphics
import Styling

/// The series color from the poster — **forwarding to ``Styling/ImageColor``.**
///
/// - Important: **Deprecated since AP58 (2026-09-26).** The drawing step from the image to
///   the pixels was the same here and on the TV; it now exists once in `Styling`. The
///   calculation itself had already been shared before (`AccentPalette.derive`).
public enum AccentExtractor {

    /// Calculated at this edge length — the same 96 as in `design/palette.py`.
    public static let edge = ImageColor.edge

    /// The series color of an image, or `nil` if it contains no color information.
    public static func color(from image: CGImage) -> AccentPalette? {
        ImageColor.color(from: image)
    }

    /// The image as RGBA bytes in ``edge`` × ``edge``.
    static func pixels(from image: CGImage) -> [UInt8]? {
        ImageColor.pixels(from: image)
    }
}
