import Core
import SwiftUI

extension Color {

    /// A colour from `0xRRGGBB`, **explicitly in the sRGB space**: The values of the board are
    /// calculated against sRGB, and `Color(red:green:blue:)` otherwise uses the extended
    /// space.
    ///
    /// On the phone the initialiser was called this, on the TV ``init(hex:)`` — two names for
    /// the same calculation. Both remain, both calculate here.
    public init(colorValue: UInt32) {
        let fractions = Color.components(hex: colorValue)
        self.init(.sRGB, red: fractions.red, green: fractions.green, blue: fractions.blue, opacity: 1)
    }

    /// The same as ``init(colorValue:)`` under the TV's name.
    public init(hex: UInt32) {
        self.init(colorValue: hex)
    }

    /// Splits a value like `0xF7EBD6` into its components, 0 to 1.
    ///
    /// A function of its own, so that the conversion can be checked without creating a colour
    /// and taking it apart again — which turns out differently depending on the platform.
    public static func components(hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// A gradation of the series colour.
    ///
    /// The steps are normalised to **luminance** and not to HLS lightness — calculated
    /// in `AccentPalette`, here only a colour is made from it.
    public init(_ seriesColor: AccentPalette, _ tier: AccentPalette.Level = .base) {
        let fractions = seriesColor.components(tier)
        self.init(.sRGB, red: fractions.red, green: fractions.green, blue: fractions.blue, opacity: 1)
    }

    /// The colour of a role in a board.
    public init(_ role: ColorRole, in board: ColorBoard) {
        self.init(colorValue: board.value(role))
    }
}
