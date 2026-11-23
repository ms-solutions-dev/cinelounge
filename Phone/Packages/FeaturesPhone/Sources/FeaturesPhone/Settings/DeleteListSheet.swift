import Core
import DesignSystemPhone
import PlaylistKit
import SwiftUI

/// Sheet: Remove this channel list?
///
/// **It names what disappears — and that is more than the list.** The channels drop out of
/// Live, out of the schedule and out of the favorites; the credentials go with them. The
/// draft spells the sentence out (`entwuerfe/prototyp.html`, `b-eb-delete`), and it
/// appears here word for word.
///
/// **Why it asks at all, when a switch sits right next to it.** Switching off can be undone,
/// deleting cannot: a switched-off list keeps credentials, groups and visibilities. Whoever
/// puts both next to each other without confirmation loses a half-hour setup while trying
/// things out.
struct DeleteListSheet: View {

    let list: Playlist
    let delete: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(appKey: "settings.lists.delete.title")
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)

            // **The list's name is shown.** "This channel list" is no information when there are two
            // lists — and it asks exactly when there is more than one.
            Text(verbatim: list.name)
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.text.color)

            Text(appKey: "settings.deleteConfirmHint")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: delete) {
                Text(appKey: "common.delete").frame(maxWidth: .infinity)
            }
            .buttonStyle(.loud)
            .padding(.top, MetricsBoard.phone.gutter)

            Button(action: cancel) {
                Text(appKey: "common.cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.vertical, MetricsBoard.phone.section)
    }
}
