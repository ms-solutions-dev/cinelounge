import Core
/// The shared styling, passed on — **whoever pulls in this layer gets both.**
///
/// Since AP58 (2026-09-26), roles, color board, contrast, symbol registry,
/// type scale, size roles, profile marks, stripe measures and the language helpers live in the shared
/// package `Styling`. The views only pull in their platform layer; this line passes
/// the package through, and the extensions below state once which device is meant.
@_exported import Styling
import SwiftUI

extension ColorBoard {

    /// The selected theme on the TV — **read from `Theme.current`**, which
    /// ``Features/ThemeStore`` sets before the first view build.
    ///
    /// **From a finished table and not rebuilt on every access:** every color of every
    /// view asks here, on every redraw. Building a board from `Theme` means
    /// looking up twenty fields and the phone board of the same theme — computing it three times
    /// is enough.
    public static var current: ColorBoard {
        let theme = Theme.current
        return tvBoards[theme.id] ?? ColorBoard(theme: theme)
    }

    private static let tvBoards: [String: ColorBoard] = Dictionary(
        uniqueKeysWithValues: all(forItem: .tv).map { ($0.id, $0) })
}

extension ColorRole {

    /// The color of this role in the TV's selected theme.
    ///
    /// **Computed and not stored:** a stored color would freeze the theme that applied at
    /// first access — a switch would get stuck.
    public var color: Color { Color(self, in: .current) }
}

extension TypeLevel {

    /// The font of this level on the TV — fixed size, no Dynamic Type.
    public var font: Font { font(.tv) }

    /// The size in points on the TV — for line heights that bound a tile.
    public var points: CGFloat { points(.tv) }

    /// How tall a line of a font size is on the TV (× 1.28, rounded up).
    public static func lineHeight(zu size: CGFloat) -> CGFloat {
        lineHeight(zu: size, .tv)
    }
}
