import Core
import CoreGraphics

/// The series colour from an image — **the step from image to pixels, once.**
///
/// The calculation itself lives in `AccentPalette.derive` and knows no image types. Until
/// 2026-09-26 the wrapper therefore existed twice (report B finding 19): as an `AccentExtractor` actor
/// on the TV (with a cache, via the TV's image store) and as an
/// `AccentExtractor` enumeration on the phone — both with the same drawing context. This part
/// is now here; fetching and keeping the image stays with the respective device, because the
/// image chains differ (own task, report B finding 20).
///
/// **It is scaled down to 96 × 96** — the same size as in `design/palette.py`, so that
/// template and app arrive at the same tone. For "which colour dominates" nine thousand
/// pixels suffice; more resolution dilutes the hue rather than sharpening it.
public enum ImageColor {

    /// The edge length on which the calculation is done.
    public static let edge = 96

    /// The series colour of an image, or `nil` if it contains no colour statement.
    public static func color(from image: CGImage) -> AccentPalette? {
        guard let points = pixels(from: image) else { return nil }
        return AccentPalette.derive(fromRGBA: points)
    }

    /// The image as RGBA bytes in ``edge`` × ``edge``.
    ///
    /// **Redrawn and not read from the original:** A loaded image can come in
    /// any colour space and any arrangement — BGRA instead of RGBA, premultiplied or
    /// not. Whoever takes the raw bytes reads blue as red for some images. With a
    /// dedicated context the arrangement is fixed.
    public static func pixels(from image: CGImage, edge page: Int = edge) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: page * page * 4)
        let succeeded = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let start = raw.baseAddress,
                let surface = CGContext(
                    data: start,
                    width: page,
                    height: page,
                    bitsPerComponent: 8,
                    bytesPerRow: page * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            surface.interpolationQuality = .medium
            surface.draw(image, in: CGRect(x: 0, y: 0, width: page, height: page))
            return true
        }
        return succeeded ? buffer : nil
    }
}
