import SwiftUI

/// The width cap for the **one** main button of a page — AP7, 2026-09-23.
///
/// **The finding:** on an iPad Pro 13″ the "Play" bar of the detail page was **945 points**
/// wide. ``DesignSystemPhone/LoudButtonStyle`` sets `maxWidth: .infinity`; what is a button at
/// 393 points is a bench at 945 — and a target that one cannot take in with one glance no
/// longer looks like a target.
///
/// **Why the cap lives here and not in ``DesignSystemPhone/LoudButtonStyle``.** That was the
/// actual decision, and it went against the obvious path:
///
/// * **The style is not the wrong place, it is the too-wide one.** `.loud` and `.quiet`
///   appear in **54 places in 28 files**, and the great majority are sheets, setup steps and
///   state views. There `maxWidth: .infinity` is exactly right: the button fills the row it
///   is given, and two buttons side by side share it. A cap in the style would, in a sheet
///   that ``MetricClass/contentCap(_:)`` already brings to 700 points, set a second cap of
///   360 — a button swimming in its own row.
/// * **The style does not know what it stands in; the page does.** "I am the main button of
///   this page" is a statement about the place, not about the look. It belongs at the place.
/// * **And the style lives in a package whose header promises fixed dimensions.**
///   ``MetricClass`` came into being for exactly that reason ("A number with two values is no
///   longer a guarantee but a case distinction"); a size-class-dependent number in
///   `DesignSystemPhone` would be the same mistake again.
///
/// The modifier cannot break anything that works today: whoever does not write it gets
/// yesterday's button.
struct PrimaryButtonWidth: ViewModifier {

    #if canImport(UIKit)
        @Environment(\.horizontalSizeClass) private var widthClass
    #endif

    /// How wide the button may become at most — `nil` means "no cap".
    ///
    /// **The `#if` is not ornament.** `UserInterfaceSizeClass` and `\.horizontalSizeClass` do not
    /// exist on macOS ("SizeClass" occurs **zero** times in `SwiftUI.swiftinterface` of the
    /// MacOSX27 SDK), and `scripts/check.sh` runs this package's tests with `swift test` on the
    /// **Mac**, not in the simulator. Without the switch this file does not compile there.
    private var cap: CGFloat? {
        #if canImport(UIKit)
            MetricClass.buttonWidth(widthClass)
        #else
            nil
        #endif
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let cap {
            // **Whoever caps also centers, and both frames therefore stand side by side.** A cap alone
            // leaves the position to the parent, and it pins to the left — exactly the bug that
            // ``StateBlock`` with its 400-point cap already had once. The second frame takes the
            // remaining width and centers the capped button within it.
            content
                .frame(maxWidth: cap)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

extension View {

    /// Caps this button to ``MetricClass/buttonWidth(_:)`` and centers it.
    ///
    /// **Only for the main button of a page** — the one the page means. For a button in a sheet,
    /// in a list or next to a second one it is wrong; see the rationale at ``PrimaryButtonWidth``.
    ///
    /// On the phone it does nothing: ``MetricClass/buttonWidth(_:)`` returns `nil` there, and the
    /// button stays the same, row for row, as before.
    func primaryButtonWidth() -> some View {
        modifier(PrimaryButtonWidth())
    }
}
