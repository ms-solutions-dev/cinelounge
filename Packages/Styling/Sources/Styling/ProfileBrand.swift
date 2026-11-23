import Foundation
import SwiftUI

/// The colour of a profile — **the six brand colours and the reader for `#RRGGBB`, once.**
///
/// **Copied until 2026-09-26** (AP58, report B finding 15): The phone carried a copy
/// of `DesignSystem/ProfileColor` with the sentence "whoever changes a value there changes it here
/// — otherwise the same person carries two colours on two devices". The colour mark travels with
/// the profile via iCloud; two tables for that are two truths about the same person.
///
/// **Fixed and not from the colour scheme:** A person keeps their colour when somebody changes the
/// scheme. **And it is never the only feature** — in the circle stands the
/// initial, in the row the name.
///
/// **The fallback for an unknown name is `nil`** — decided on 2026-09-26. The
/// two devices fell back differently (TV to `brandBright`, phone to the
/// raised surface), and both fallbacks were justified at their place: Which surface
/// is right "without a brand colour" is known by the call site, not by the table. The platform layers
/// keep their fallback (``ProfileGradient/fallback``) so that nothing visibly changes.
public enum ProfileBrand {

    /// The six brand colours in the order of the brightness ladder.
    public static let names = ["koralle", "flieder", "moos", "schiefer", "tuerkis", "bernstein"]

    /// The numeric value of a brand colour, or `nil` for a name that does not exist.
    ///
    /// **The six values are calculated and not chosen.** The first set failed its
    /// own check: Amber and turquoise were at 1.01 : 1, in greyscale therefore the same
    /// circle. Now the hue lies in the name and the **brightness on a ladder**:
    /// 4.8 — 5.5 — 6.3 — 7.2 — 8.3 — 9.5 against the ground, each step about 1.14 : 1.
    ///
    /// **Via the name and not via `ProfileKit.ColorTag`**, so that the design does not
    /// have to know `ProfileKit`.
    public static func value(_ name: String) -> UInt32? {
        switch name {
        case "koralle": 0xB1_63_50
        case "flieder": 0x98_71_C4
        case "moos": 0x62_9B_46
        case "schiefer": 0x83_9A_AE
        case "tuerkis": 0x48_B3_AC
        case "bernstein": 0xD3_A8_50
        default: nil
        }
    }

    /// The numeric value from `#E2564A` — hash sign may be missing, upper and lower case equal.
    ///
    /// **`nil` instead of an invented colour:** An unreadable word does not yield a black
    /// circle that would be invisible on this surface. Six digits only — a short form does not
    /// come from the server.
    public static func value(from word: String?) -> UInt32? {
        guard var text = word?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return value
    }

    /// The colour of a brand colour, or `nil`.
    public static func color(_ name: String) -> Color? {
        value(name).map { Color(colorValue: $0) }
    }

    /// The colour from `#RRGGBB`, or `nil`.
    public static func color(from word: String?) -> Color? {
        value(from: word).map { Color(colorValue: $0) }
    }
}
