import DesignSystem
import SwiftUI

/// **The measurements of a settings row — in one place** (AP26, 2026-09-11).
///
/// **The finding that triggered this package is a list of numbers.** In 5275 lines,
/// `Settings/` contained exactly **one** shared building block (``SettingsHeader``); every
/// area built its own rows. Counted on 2026-09-11, that came to this for one and the
/// same thing — a row you can select:
///
/// * **four** horizontal paddings: 24, 26, 30, 34
/// * **five** vertical ones: 12, 14, 15, 16, 18
/// * **three** outlines: capsule, rectangle with radius 12, rectangle with radius 14
///
/// Twenty combinations for one row. On one screen side by side you don't see any of
/// them individually — you see that it isn't cast from one mold. **That is the
/// reason the two apps side by side don't look like a family**, and it
/// isn't in a color or a typeface, but in four points of padding.
///
/// **The height is computed, not set** — the same rule as in
/// ``SettingsView/entryHeight``: A copied number doesn't notice when the font
/// changes, and that has already happened twice in this project.
enum SettingsMetrics {

    /// Vertical padding — **the same number as in the area list.**
    ///
    /// This keeps a row in the content in the same rhythm as a row in the list next to
    /// it, even though the two use different font sizes: The list comes to
    /// 38 + 24 = 62 pt, the content to 35 + 24 = 59. **Same increment, not same
    /// height** — a fixed height for both would mean artificially stretching the smaller
    /// font.
    ///
    /// **Here and not in ``SettingsView``**, although the list derived the value first:
    /// A measurement needs no actor, and `SettingsView` is a view — its statics are bound
    /// to the main actor. Same case as ``StripeBand`` in AP27.
    static let vertical: CGFloat = 12

    /// Horizontal padding in the **content**, not in the list.
    ///
    /// **Two numbers are right here and one would be wrong:** The area list runs
    /// in a 380 pt wide column and gets by with 18; the content has all the
    /// remaining width. An inset belongs to its column and is not a property of the
    /// app. Of the four values found, 26 is the most common (17 of 38
    /// occurrences) — so the unification moves as little as possible.
    static let horizontal: CGFloat = 26

    /// The radius of a row that takes the full width.
    static let radius: CGFloat = 14

    /// Between the symbol and the label.
    static let spacing: CGFloat = 14

    /// A small button that carries only a symbol.
    ///
    /// **The numbers appeared twice and were the same both times** — in
    /// ``LiveSettings`` as `toggleWidth`/`toggleHeight`, in ``OtherSettings`` as
    /// literals. Two equal numbers in two places are not consistency but a
    /// coincidence that ends at the first refactor.
    static let iconButton = CGSize(width: 56, height: 46)

    /// How tall a row stands at this font size.
    static func height(forItem size: CGFloat = TypeLevel.footer.points) -> CGFloat {
        TypeLevel.lineHeight(zu: size) + 2 * vertical
    }
}

/// **Pill, row or symbol button — and this is not a matter of taste.**
///
/// * ``pill`` is a **choice among several, side by side**. The round outline says:
///   these are siblings, pick one. Languages, color schemes, age ratings.
/// * ``row`` takes the **full width** and stacks vertically. The rectangle says:
///   this is a list, each row on its own. Channel lists, libraries, switches.
/// * ``readingRow`` can be selected, but it **does nothing**: the version number under
///   "About", a row of the diagnostic trace, the state of a portal. It must be able to
///   take focus, because an area without a focus target **never scrolls** on tvOS —
///   everything below the edge would be unreachable. Its highlight is therefore
///   deliberately quieter: a raised surface instead of the bright capsule. **It should be
///   recognizable as entered, not as a prompt to press.**
/// * ``character`` is a small button that carries **only a symbol** — the four per
///   group row, the three per Home row. It has a fixed size instead of
///   padding, because four of them in a row would otherwise end up with different widths.
///
/// Both were found mixed up: the same on/off switch once as a capsule
/// and once as a rectangle, depending on which file it was in.
enum RowKind {
    case pill
    case row
    case readingRow
    case character
}

extension View {

    /// The surface of a settings row — **padding, outline and focus color in
    /// one grip.**
    ///
    /// **The color inversion in focus stays**, here as in the area list: At
    /// three meters a scale-up alone doesn't carry when the surface is already a
    /// surface. The scale-up comes additionally from ``FocusHighlight`` and is
    /// **not** attached here — it belongs to the button and not to the surface, and two
    /// places for the same highlight would drift apart.
    ///
    /// - Parameters:
    ///   - art: Whether the row stands next to siblings, on its own, or is only a symbol.
    ///   - imFokus: Whether focus is currently here.
    ///   - grund: The surface outside focus. The default is ``Styling/ColorRole/surface``
    ///     — a ``RowKind/readingRow`` usually wants ``SwiftUI/Color/clear``;
    ///     whoever also shows a state in the surface — a switched-off row
    ///     more muted than a switched-on one —, passes it in.
    ///   - breite: A fixed width for buttons that must be equally wide in a row.
    ///     Without it, the row is as wide as its content.
    func settingsSurface(
        _ kind: RowKind,
        isFocused: Bool,
        reason: Color = ColorRole.surface.color,
        width: CGFloat? = nil
    ) -> some View {
        modifier(SettingsSurface(kind: kind, isFocused: isFocused, reason: reason, width: width))
    }

    /// The text color that belongs to ``settingsSurface(_:isFocused:reason:width:)``.
    ///
    /// **Together with the surface and not separately:** Whoever inverts the surface and
    /// forgets the text gets light text on a light background — and that is not a
    /// cosmetic flaw but an unreadable row.
    /// - Parameter warnend: For the two buttons that remove something — "Sign Out" and
    ///   "Forget Certificate". **In focus, the red also turns to dark on light:** Red
    ///   text on the cream-colored focus surface reached a contrast ratio that no longer
    ///   carries at three meters, and the warning is in the word anyway.
    func settingsFont(
        isFocused: Bool, muted: Bool = false, warning: Bool = false
    ) -> some View {
        foregroundStyle(
            isFocused
                ? ColorRole.reason.color
                : (warning
                    ? ColorRole.live.color
                    : (muted ? ColorRole.textMatt.color : ColorRole.text.color)))
    }
}

/// Siehe ``SwiftUI/View/settingsSurface(_:isFocused:reason:width:)``.
struct SettingsSurface: ViewModifier {
    let kind: RowKind
    let isFocused: Bool
    let reason: Color
    let width: CGFloat?

    func body(content: Content) -> some View {
        let color = isFocused ? ColorRole.text.color : reason

        switch kind {
        case .character:
            content
                .frame(width: SettingsMetrics.iconButton.width, height: SettingsMetrics.iconButton.height)
                .background(
                    color,
                    in: RoundedRectangle(cornerRadius: MetricsBoard.tv.cardRadius, style: .continuous))
        case .pill:
            content
                .padding(.horizontal, SettingsMetrics.horizontal)
                .padding(.vertical, SettingsMetrics.vertical)
                .frame(width: width)
                .background(color, in: Capsule())
        case .row:
            content
                .padding(.horizontal, SettingsMetrics.horizontal)
                .padding(.vertical, SettingsMetrics.vertical)
                .frame(width: width)
                .background(
                    color,
                    in: RoundedRectangle(cornerRadius: SettingsMetrics.radius, style: .continuous))
        case .readingRow:
            content
                .padding(.horizontal, SettingsMetrics.horizontal)
                .padding(.vertical, SettingsMetrics.vertical)
                .frame(width: width)
                .background(
                    isFocused ? ColorRole.surfaceHigh.color : reason,
                    in: RoundedRectangle(cornerRadius: SettingsMetrics.radius, style: .continuous))
        }
    }
}
