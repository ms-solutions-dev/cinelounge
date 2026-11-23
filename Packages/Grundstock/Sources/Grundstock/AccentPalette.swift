import Foundation

/// The key color of a series, derived from its imagery.
///
/// The derivation itself lives in ``AccentPalette/derive(fromHue:saturation:)``.
/// Two findings from the comparison against the real library are recorded here
/// and should not be thrown away again:
///
/// - The color comes from the **backdrop image**, not from the poster. Posters
///   are often photographed covers whose packaging frame wins every
///   evaluation — one series came out blue instead of orange that way.
/// - Normalization targets **perceived** lightness, not the computed
///   brightness value. Otherwise a yellow-green shines many times
///   brighter than a red with the same number, and the accents
///   look unevenly strong across the library.
public struct AccentPalette: Sendable, Equatable, Hashable, Codable {

    /// Hue on the color wheel, 0 to 360 degrees.
    public let hue: Double
    /// Saturation, 0 to 1.
    public let saturation: Double

    public init(hue: Double, saturation: Double) {
        self.hue = hue.truncatingRemainder(dividingBy: 360)
        self.saturation = min(max(saturation, 0), 1)
    }

    /// Target perceived-lightness values for the three levels.
    /// Light enough to glow on a dark background, dark enough that cream-colored
    /// text on top still holds.
    ///
    /// **`base` is computed against the text, not chosen.** The base level carries
    /// the surfaces on which the pattern's text sits — active filter buttons,
    /// the current season, focused offers. At 0.22 the cream text reached only
    /// about 3.3:1 there, and because the lightness is pinned here, that held
    /// for **every** hue — our own limit of 4.5:1 for ordinary text
    /// (see ``Theme/contrastRatio(_:_:)``) was missed across the board, and in
    /// exactly the state that carries information. 0.14 lifts the worst
    /// case (the cream of the cinema pattern) to 4.7:1; the test suite holds the limit
    /// for all patterns and hues.
    public enum Level: Double, Sendable, CaseIterable {
        case deep = 0.045
        case base = 0.14
        case bright = 0.42
    }

    /// The brand itself. Applies wherever no series color is set yet.
    ///
    /// **Comes from the color pattern and is no longer fixed.** It carries the focus, the
    /// brand symbol and every highlight as long as the color from the image has not yet been
    /// derived. If it stayed the red of the armchair, a cool pattern would have
    /// a red focus — and that does not look like a different design but like
    /// a bug.
    public static var brand: AccentPalette { Theme.current.accent }

    /// Red, green and blue components (0 to 1) for the requested level.
    public func components(_ level: Level) -> (red: Double, green: Double, blue: Double) {
        Self.rgb(hue: hue, saturation: saturationFor(level), targetLuminance: level.rawValue)
    }

    public func hex(_ level: Level) -> String {
        let c = components(level)
        return String(
            format: "#%02X%02X%02X",
            Int((c.red * 255).rounded()),
            Int((c.green * 255).rounded()),
            Int((c.blue * 255).rounded())
        )
    }

    private func saturationFor(_ level: Level) -> Double {
        switch level {
        case .deep: min(saturation + 0.06, 0.95)
        case .base: saturation
        case .bright: min(saturation + 0.04, 0.92)
        }
    }

    // MARK: - Farbrechnung

    /// Perceived lightness by the usual weighting: green contributes by
    /// far the most, blue the least.
    static func relativeLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Searches for the lightness level at which a hue reaches the desired
    /// perceived lightness. There is no closed formula for it, so it
    /// bisects — with 24 steps the error is far below one displayable level.
    static func rgb(
        hue: Double,
        saturation: Double,
        targetLuminance: Double
    ) -> (red: Double, green: Double, blue: Double) {
        var low = 0.0
        var high = 1.0
        var result = (red: 0.0, green: 0.0, blue: 0.0)

        for _ in 0..<24 {
            let mid = (low + high) / 2
            result = hslToRGB(hue: hue, saturation: saturation, lightness: mid)
            if relativeLuminance(result.red, result.green, result.blue) < targetLuminance {
                low = mid
            } else {
                high = mid
            }
        }
        return result
    }

    static func hslToRGB(
        hue: Double,
        saturation: Double,
        lightness: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let hp = hue.truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2

        let (r, g, b): (Double, Double, Double) =
            switch hp {
            case 0..<1: (c, x, 0)
            case 1..<2: (x, c, 0)
            case 2..<3: (0, c, x)
            case 3..<4: (0, x, c)
            case 4..<5: (x, 0, c)
            default: (c, 0, x)
            }

        return (r + m, g + m, b + m)
    }
}

// MARK: - Ableitung aus Bildpunkten

extension AccentPalette {

    /// How many bins the color wheel is divided into.
    ///
    /// Thirty gives sections of twelve degrees — finer than the eye distinguishes at three
    /// meters, and coarse enough that a slightly scattered hue
    /// stays together.
    static let hueBuckets = 30

    /// From this saturation on, a pixel counts as a color statement and not as gray.
    ///
    /// The value comes from the comparison against the real library: below it,
    /// the gray areas that dominate almost every image win, and all
    /// series get the same pale accent.
    public static let minimumSaturation = 0.45

    /// Derives the key color from pixels.
    ///
    /// Expects **RGBA**, four bytes per pixel, as a bitmap delivers it. A
    /// pure computation without image types, so it can be checked with invented values
    /// and not only with real images.
    ///
    /// Returns `nil` if the image contains no color statement — for a
    /// grayscale image, say. Then the brand color applies, and that is right: a
    /// guessed color would be worse than a deliberately chosen one.
    ///
    /// The method comes from `design/palette.py`, where it was checked against real
    /// library images. Three subtleties carry the result:
    ///
    /// 1. **Weighted by saturation squared.** One vivid pixel counts
    ///    more than four pale ones — otherwise the quantity decides instead of the statement.
    /// 2. **Medium lightness counts most.** Highlights and shadows
    ///    carry hardly any color, yet push to the front in every count.
    /// 3. **Neighboring bins are counted too.** A hue scattered across two bins
    ///    would otherwise lose against a narrow, coincidentally concentrated one.
    public static func derive(
        fromRGBA pixels: [UInt8],
        minimumSaturation: Double = AccentPalette.minimumSaturation
    ) -> AccentPalette? {
        guard pixels.count >= 4 else { return nil }

        var weights = [Double](repeating: 0, count: hueBuckets)
        var saturationSums = [Double](repeating: 0, count: hueBuckets)
        var saturationCounts = [Int](repeating: 0, count: hueBuckets)

        var index = 0
        while index + 3 < pixels.count {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let alpha = Double(pixels[index + 3]) / 255
            index += 4

            // Transparent pixels carry no color. Counting them would mean
            // counting the black that sits behind them in memory.
            guard alpha > 0.5 else { continue }

            let hls = Self.hls(r, g, b)
            guard hls.saturation >= minimumSaturation,
                hls.lightness > 0.10,
                hls.lightness < 0.92
            else { continue }

            let bucket = min(Int(hls.hue / 360 * Double(hueBuckets)), hueBuckets - 1)
            let midweight = 1 - abs(hls.lightness - 0.5) * 1.4
            weights[bucket] += hls.saturation * hls.saturation * max(midweight, 0.05)
            saturationSums[bucket] += hls.saturation
            saturationCounts[bucket] += 1
        }

        guard weights.contains(where: { $0 > 0 }) else { return nil }

        var best = 0
        var bestWeight = -1.0
        for bucket in 0..<hueBuckets {
            let left = weights[(bucket - 1 + hueBuckets) % hueBuckets]
            let right = weights[(bucket + 1) % hueBuckets]
            let smoothed = weights[bucket] + 0.6 * (left + right)
            if smoothed > bestWeight {
                bestWeight = smoothed
                best = bucket
            }
        }

        // The center of the bin, not its edge.
        let hue = (Double(best) + 0.5) / Double(hueBuckets) * 360

        // Saturation from the winning bin and its neighbors — the same
        // neighborhood as in the selection, otherwise the value does not match the hue.
        var sum = 0.0
        var count = 0
        for offset in -1...1 {
            let bucket = (best + offset + hueBuckets) % hueBuckets
            sum += saturationSums[bucket]
            count += saturationCounts[bucket]
        }

        // Bounded below so the accent carries; bounded above so it does not
        // turn garish. With no pixels in the bin, a medium value.
        let average = count > 0 ? sum / Double(count) : 0.72
        return AccentPalette(hue: hue, saturation: min(max(average, 0.6), 0.9))
    }

    /// Hue in degrees, lightness and saturation — the representation in which
    /// "which color is this" can be answered.
    static func hls(
        _ r: Double, _ g: Double, _ b: Double
    )
        -> (hue: Double, lightness: Double, saturation: Double)
    {
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let lightness = (maximum + minimum) / 2

        guard maximum > minimum else { return (0, lightness, 0) }

        let delta = maximum - minimum
        let saturation =
            lightness > 0.5
            ? delta / (2 - maximum - minimum)
            : delta / (maximum + minimum)

        var hue: Double
        switch maximum {
        case r: hue = (g - b) / delta + (g < b ? 6 : 0)
        case g: hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        hue *= 60

        return (hue, lightness, saturation)
    }
}
