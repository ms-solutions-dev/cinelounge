import SwiftUI

/// An **icon** of fixed base size that grows with the system type size.
///
/// **The finding (AP5): 37 places stood off the scale (today ``Styling/TypeLevel``).**
/// This project's type scale is built correctly — `largeTitle`, `title`, `headline`, all text
/// styles, all scaling. Next to it stood `.font(.system(size: 11))` and the like, and
/// `Font.system(size:)` is **fixed** in SwiftUI: whoever sets the system type to
/// `accessibilityExtraExtraExtraLarge` gets an app in which the text grows to 48 points and
/// the chevron next to it stays at eleven. Not only small — at that setting simply no longer
/// visible.
///
/// **Why the size nevertheless stays a number and does not become a text style.** A chevron
/// of eleven points next to a row caption of seventeen is a design specification: the symbol
/// is meant to be **smaller** than the type next to it. Giving it
/// ``Styling/TypeLevel/lowercased`` would put there the type size of an all-caps label, and
/// that one is eleven for a different reason. What was missing was not the style but the
/// growing.
///
/// **The construction was already in the project — in exactly one place.** ``TabBar``
/// has computed its caption via `UIFontMetrics` since 2026-09-05, with the comment "Growing, not
/// fixed … the one place that fell out of line". It was not the only one to fall out; it was
/// the only one that was brought back.
///
/// **And the hit area remains untouched.** An icon may be small and must still be 44 × 44
/// hittable — that is in `GESTALTUNG.md` §3 and is not regulated here as well: whoever
/// changes the size should not change the target unasked.
public struct IconSize: ViewModifier {

    /// **The detour via one hundred.** `ScaledMetric` scales a value; one hundred is the
    /// reference size from which the factor can be read off without asking for it. Scaling the
    /// point count directly would work too — but then every call would need its own
    /// `ScaledMetric`, and that does not work in a modifier whose number comes from outside.
    @ScaledMetric(relativeTo: .body) private var factor: CGFloat = 100

    let points: CGFloat
    let weight: Font.Weight
    /// For the places where the shape of the type carries the information — a connection number
    /// in monospaced digits, a number pad in round ones.
    let design: Font.Design

    public func body(content: Content) -> some View {
        content.font(.system(size: points * factor / 100, weight: weight, design: design))
    }
}

extension View {

    /// See ``IconSize``.
    public func iconSize(
        _ points: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default
    ) -> some View {
        modifier(IconSize(points: points, weight: weight, design: design))
    }
}
