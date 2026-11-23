/// The shared design, passed on — **whoever includes this layer has both.**
///
/// Since AP58 (2026-09-26), roles, color board, contrast, symbol register, type scales,
/// measure roles, profile marks, strip measures and the language aids live in the shared
/// package `Styling`. The views include only their platform layer; this line passes the
/// package through, and the extensions below say once which device is meant.
@_exported import Styling
import SwiftUI

@MainActor
extension ColorBoard {

    /// The chosen scheme on the phone. Set at startup and by Settings (area 6); until the
    /// closing step of AP58 it was called `ColorBoard.current`.
    ///
    /// The appearance is dark and is not switched; that is fixed via `UIUserInterfaceStyle` in
    /// `project.yml`. All contrast values are calculated against the dark ground.
    public static var current: ColorBoard = .phoneCinema
}

@MainActor
extension ColorRole {

    /// The color of this role in the phone's chosen scheme.
    ///
    /// **Computed and not stored:** a stored color would hold on to the scheme that applied at
    /// the first access — a switch would stay stuck.
    public var color: Color { Color(self, in: .current) }
}

extension TypeLevel {

    /// The font of this level on the phone — a text style that grows with Dynamic Type.
    ///
    /// The eight levels hit the iOS text styles point for point (34 · 28 · 22 · 17 · 17 · 15 ·
    /// 13 · 11); through them Dynamic Type comes at every level for free. Fixed point sizes
    /// would break at XXL, and first where nobody tries it.
    ///
    /// - Note: ``lead`` gets `minimumScaleFactor(0.8)` and **no** fixed height. At XXL it
    ///   would otherwise grow to 48 points and push the search field and chips out of view.
    ///   ``lowercased`` is the smallest level; the tracking of +0.6 points for all-caps marks such as
    ///   `LIVE` is set by the call site with `.tracking(0.6)`.
    public var font: Font { font(.phone) }

    /// The base size of the text style in points.
    public var points: CGFloat { points(.phone) }

    /// Line height for a font size on the phone: size × 1.3, rounded up.
    ///
    /// Needed only where a line bounds a tile and the height is therefore fixed. Everywhere else
    /// the font sets it itself — and with Dynamic Type it has to.
    public static func lineHeight(zu size: CGFloat) -> CGFloat {
        lineHeight(zu: size, .phone)
    }
}
