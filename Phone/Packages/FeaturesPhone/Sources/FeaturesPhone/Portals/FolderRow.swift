import DesignSystemPhone
import SwiftUI

/// A folder row — **a door, not a title.**
///
/// **Why a row and not a poster.** Measured at the bridge, four of eight
/// Serieshub entry points deliver pure folder lists: 30, 24, 18 and 27 entries, **not a single
/// image**. As a poster grid that would be thirty empty frames with text below — three times as
/// tall as needed and without a single piece of information more. The rule for this is at
/// ``PortalLayer/areFolders`` and decides **per level**, not per entry.
///
/// **The chevron says "leads deeper" and the name says where.** There is no symbol for the
/// kind: the bridge reports none, and inventing one would mean giving thirty genres the
/// same folder icon — a column that says the same thing for all rows.
struct FolderRow: View {

    let entry: PortalEntry

    /// Whether a level is currently being fetched behind this row.
    ///
    /// **Finding of 2026-09-09: below the root there was no feedback at all.**
    /// `PortalsModel.enter` shows the loading state only on the root; one level deeper
    /// the screen stood unchanged until the answer came. With flatone that takes
    /// one to two seconds — and a button that does nothing for a second is, to the
    /// thumb, a broken button, so it gets pressed a second time.
    ///
    /// **The spinner stands in the place of the chevron and not next to it.** Both say
    /// the same thing about the same row — "here it goes on" and "something is
    /// opening here right now"; side by side the row would be wider when pressed than before.
    var isLoading = false

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MetricsBoard.phone.gutter) {
                Text(verbatim: entry.title)
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: Metrics.targetSpacing)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(ColorRole.textMatt.color)
                } else {
                    Image(systemName: Glyph.next.name)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .frame(minHeight: Metrics.choiceRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Divider().overlay(ColorRole.lineQuiet.color).padding(.leading, MetricsBoard.phone.margin)
        }
    }
}
