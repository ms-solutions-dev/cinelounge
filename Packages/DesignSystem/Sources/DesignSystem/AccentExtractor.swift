import Core
import CoreGraphics
import Foundation
import Styling

// The same pattern as in the image cache: it is built for the TV,
// tested on the Mac. Without both branches the tests do not run.
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Determines the accent colour of an image and keeps the result.
///
/// The calculation itself lives in ``AccentPalette/derive(fromRGBA:minimumSaturation:)``
/// and knows no image types. What is added here is only what is needed for it: fetch
/// the image, shrink it, get at the pixels.
///
/// **It is shrunk to 96 × 96.** A background image has two million
/// pixels; checking all of them took noticeably long on every focus change
/// and changed nothing in the result — for "which colour predominates" nine thousand
/// suffice. The template in `design/palette.py` uses the same size so that
/// both sides arrive at the same tone.
public actor AccentExtractor {

    public static let shared = AccentExtractor()

    private var cache: [String: AccentPalette] = [:]
    /// Addresses that have already yielded nothing once. Without this memory
    /// a greyscale image would be reloaded and recalculated on every focus change.
    private var barren: Set<String> = []

    private let side = ImageColor.edge

    public init() {}

    /// The accent colour for the image behind the address, or `nil`.
    ///
    /// `nil` means "no colour statement" and is not an error — the caller then
    /// takes the brand colour.
    public func palette(for url: URL?) async -> AccentPalette? {
        guard let url else { return nil }
        let key = url.absoluteString

        if let known = cache[key] { return known }
        if barren.contains(key) { return nil }

        // Without staying in memory: this image is never drawn, and it
        // would otherwise displace the posters that are currently visible.
        guard let image = await ImageCache.shared.platformImage(for: url, keepInMemory: false),
            let pixels = Self.rgba(from: image, side: side),
            let palette = AccentPalette.derive(fromRGBA: pixels)
        else {
            barren.insert(key)
            return nil
        }

        cache[key] = palette
        return palette
    }

    public func clear() {
        cache.removeAll()
        barren.removeAll()
    }

    // MARK: - Pixels

    /// Draws the image small and delivers its pixels as RGBA — **the drawing step
    /// itself has stood once in ``Styling/ImageColor`` since AP58**; only the path
    /// from this platform's image to the `CGImage` remains here.
    static func rgba(from image: PlatformImage, side: Int) -> [UInt8]? {
        guard let source = Self.bitmap(from: image) else { return nil }
        return ImageColor.pixels(from: source, edge: side)
    }

    /// The image in the form from which pixels can be drawn.
    static func bitmap(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
            return image.cgImage
        #elseif canImport(AppKit)
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
            return nil
        #endif
    }
}

extension AccentExtractor {

    /// Width at which the image is fetched solely for colour determination.
    ///
    /// **240 points, not 1920.** For "which colour predominates" no resolution is
    /// needed, and the image is shrunk to 96 × 96 anyway. A
    /// full-width background image weighs about 200 kilobytes, this one about
    /// fifteen — when browsing a grid that is the difference
    /// between fluid and sluggish, especially over a narrow line.
    public static let sourceWidth = 240
}
