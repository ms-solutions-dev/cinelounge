import DesignSystemPhone
import SwiftUI

/// A chip.
///
/// **Filter chips are targets and at least 44 points tall** — also in width, because "All" is
/// only three letters long and would otherwise be a target of 38 points.
///
/// **Info chips are not targets** (year, FSK, runtime on the detail page) and stay small.
/// They carry the same border because otherwise they would look like half buttons — but they
/// are not, and the hit area makes the difference.
struct Chip: View {

    /// A key in the language catalog.
    var title: String?

    /// Finished wording — for names that the server or a count supplies.
    var wording: String?

    var on = false
    /// `nil` turns it into an info chip instead of a target.
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { caption }
                .buttonStyle(.chip(active: on))
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        } else {
            caption
                .padding(.horizontal, Metrics.pillInset)
                .frame(minHeight: 26)
                .background(ColorRole.surface.color, in: Capsule())
                .edge()
        }
    }

    /// **One line, never two.** A chip that wraps is no longer a chip but a box with hyphenation:
    /// "Sea-son 1" appeared on screen. `fixedSize` tells the capsule that it has to follow the
    /// word and not the other way around.
    @ViewBuilder
    private var caption: some View {
        if let wording {
            Text(verbatim: wording).font(TypeLevel.label.font).lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } else if let title {
            Text(appKey: title).font(TypeLevel.label.font).lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
