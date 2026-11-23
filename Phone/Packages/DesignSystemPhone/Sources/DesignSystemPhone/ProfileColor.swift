import Styling
import SwiftUI

/// The color of a profile circle — **forwarding to ``Styling/ProfileBrand``.**
///
/// - Important: **Deprecated since AP58 (2026-09-26).** Until then a copy of the TV version;
///   values and readers now live once in `Styling`. The phone keeps its fallback `nil` —
///   the call site then uses its muted surface (``Styling/ProfileGradient/fallback``).
public enum ProfileColor {

    /// From `#E2564A` a color, or `nil`.
    public static func from(_ word: String?) -> Color? {
        ProfileBrand.color(from: word)
    }

    /// The numeric value from `#RRGGBB`, or `nil`.
    public static func value(from word: String?) -> UInt32? {
        ProfileBrand.value(from: word)
    }

    /// The color of a `ProfileKit.ColorTag`, or `nil` for an unknown name.
    public static func tag(_ name: String) -> Color? {
        ProfileBrand.color(name)
    }

    /// The numeric value of a mark, or `nil`.
    public static func brandValue(_ name: String) -> UInt32? {
        ProfileBrand.value(name)
    }
}
