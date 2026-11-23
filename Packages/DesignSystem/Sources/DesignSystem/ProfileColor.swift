import Styling
import SwiftUI

/// The color of a profile circle — **forwarding to ``Styling/ProfileBrand``.**
///
/// - Important: **Deprecated since AP58 (2026-09-26).** Values and readers now live once in
///   `Styling` and are no longer copied on both devices. This wrapper keeps only the
///   **TV's fallback**: an unknown mark draws in the light brand color
///   (``Styling/ProfileGradient/fallback``), so that a circle is visible from three meters —
///   an invisible circle would be a drawing bug.
public enum ProfileColor {

    /// A color from `#E2564A`, or `nil`.
    public static func from(_ word: String?) -> Color? {
        ProfileBrand.color(from: word)
    }

    /// The numeric value from `#RRGGBB`, or `nil`.
    public static func value(from word: String?) -> UInt32? {
        ProfileBrand.value(from: word)
    }

    /// The color of a mark; for an unknown name ``Styling/ColorRole/brandLight``.
    public static func tag(_ name: String) -> Color {
        ProfileBrand.color(name)
            ?? Color(ProfileGradient.forItem(.tv).fallback, in: ColorBoard.current)
    }

    /// The numeric value of a mark, or `nil`.
    public static func brandValue(_ name: String) -> UInt32? {
        ProfileBrand.value(name)
    }
}
