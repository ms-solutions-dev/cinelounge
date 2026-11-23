import SwiftUI

/// What only the TV knows: focus.
///
/// **Since the final step of AP58 (2026-09-26) only this lives here.** Colors,
/// type and the shared measures are named by the views via `Styling`
/// (``Styling/ColorRole``, ``Styling/TypeLevel``, ``Styling/MetricsBoard``); what
/// only the TV needs comes via ``TVMetrics``.
public enum Tokens {

    // MARK: - Focus
    //
    // On tvOS focus is the only pointer. To keep it unambiguous across the width of the room,
    // three means work together: enlargement, ring in the
    // series color and a shadow that lifts the element off the background. One
    // alone is not enough.

    public enum Focus {
        /// Without a frame the enlargement has to carry the highlight alone —
        /// hence somewhat more distinct than before. At 1.08 the difference was hardly visible at
        /// three meters distance once the line was missing.
        public static let cardScale: CGFloat = 1.12
        public static let buttonScale: CGFloat = 1.06
        public static let shadowRadius: CGFloat = 60
        public static let shadowY: CGFloat = 24

        /// Apple's curve for focus changes.
        public static let animation = Animation.timingCurve(0.2, 0.7, 0.3, 1, duration: 0.22)
    }
}

/// The measures that **only the TV** knows — next to the shared roles in
/// ``Styling/MetricsBoard/tv``.
///
/// All measures are **points** at 1920×1080. That is the surface tvOS lays out —
/// **not** the one it draws into: an Apple TV 4K draws at scale 2, that is in
/// 3840×2160 pixels. This surface applies to layout; for everything that computes in pixels,
/// ``ImageSizing``.
public enum TVMetrics {

    /// Distance to the top and bottom screen edge. Outside of it some TVs
    /// crop. The lateral one is in the shared board as ``Styling/MetricsBoard/margin``.
    public static let topMargin: CGFloat = 60

    /// The space that a title logo takes up at most.
    ///
    /// One value for header and detail page, although their frames differ by twenty
    /// points: two values would mean two requested widths, two
    /// fetches and two decoded images for the same logo. The difference is
    /// smaller than the rounding that is applied anyway.
    public static let logo = CGSize(width: 460, height: 124)
}
