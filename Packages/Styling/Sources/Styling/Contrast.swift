import Core

/// Contrast calculation according to WCAG 2.2 — **the thresholds here, the formula in `Grundstock`.**
///
/// **Until 2026-09-26 the formula existed twice** (AP58, report B finding 14): as
/// `Theme.contrastRatio` in `Grundstock` and as a re-implementation in `DesignSystemPhone`. The
/// comment in `Theme` has demanded the replacement since AP28. Two versions of a
/// threshold calculation only get noticed when one is corrected — by then one of the two
/// apps has been coloured for months against the wrong threshold. Now this file does not
/// calculate itself but calls `Theme`; what it contributes are the thresholds that both devices
/// apply equally.
public enum Contrast {

    /// Body text and everything under 18 points.
    public static let bodyText = 4.5

    /// Large text — from 18 points, or from 14 points semibold.
    public static let largeText = 3.0

    /// The outline of a control (WCAG 1.4.11).
    ///
    /// Numerically equal to ``largeText`` and still a constant of its own: It is a
    /// different rule, and if one of the two changes, the other should stay put.
    public static let control = 3.0

    /// The relative luminance of a colour `0xRRGGBB`, 0 to 1.
    public static func luminance(_ color: UInt32) -> Double {
        Theme.relativeLuminance(color)
    }

    /// The contrast ratio of two colours, 1 to 21. The order does not matter.
    public static func ratio(_ single: UInt32, _ other: UInt32) -> Double {
        Theme.contrastRatio(single, other)
    }

    /// Whether a colour on a background meets the required threshold.
    public static func carries(
        _ foreground: UInt32, to rearmost: UInt32, atLeast threshold: Double
    )
        -> Bool
    {
        ratio(foreground, rearmost) >= threshold
    }
}
