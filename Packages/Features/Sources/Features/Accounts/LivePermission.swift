import Core
import DesignSystem
import ParentalControls
import ProfileKit
import SwiftUI

/// **The allow list for Live, as a list to tick** — the second level behind the
/// row of a child in the parental controls (AP52, Decision 14; canvas K4b in
/// `design/childInterface.html`).
///
/// **Behind the parental-controls door and not on the profile sheet.** The profile sheet carries
/// the limit, because every adult sets it right away when creating a child. The
/// channel groups are a review: 79 groups of one provider, of which a parent
/// looks at a handful. It belongs where adult channels and assignments
/// also live — behind the PIN.
///
/// **Layout like the second level under "Live" (AP46):** header with sentence, below it one row
/// per group, Menu button back. Unlike there there is **no collective button "allow
/// all"** — it would be the one press that releases the whole list of a provider, and
/// exactly that is what this list should not be able to do. Only "deselect all".
struct LiveAllowList: View {

    /// Wessen Liste.
    let person: Profile

    /// What can be chosen — ``ParentalControls/ChannelApproval/selectable(_:)`` over the
    /// catalog.
    let choice: [ChannelApproval.Choice]

    /// The names of the channel lists, per identifier — for the headers, if there is more than one.
    let listNames: [String: String]

    /// The stored list of this child.
    let approval: ChannelApproval

    /// Stores a changed list.
    let update: (ChannelApproval) -> Void

    let focus: FocusState<String?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("childLock.live", hint: "childLock.liveListHint")
            // **Whose list — large and above everything.** Whoever has two children should not
            // guess which list they are currently ticking.
            Text(verbatim: person.name)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
                .padding(.bottom, 18)

            let rows = LivePermission.rows(choice: choice, approval: approval)
            if rows.isEmpty {
                Text(app: "childLock.liveNoStock")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
                    // An area without a focus target never scrolls on tvOS — and the way back
                    // via the Menu button needs a focus in this area.
                    .focusable()
                    .focused(focus, equals: "live-leer")
            } else {
                deselect
                // **All rows in one VStack** — the same reasoning as at the
                // group list under "Live": Focus only moves reliably between
                // siblings.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(LivePermission.blocks(rows)) { block in
                        if LivePermission.hasMultipleLists(rows) {
                            Text(verbatim: listNames[block.list] ?? block.list)
                                .font(TypeLevel.header.font)
                                .foregroundStyle(ColorRole.text.color)
                                .padding(.top, 30)
                                .padding(.bottom, 8)
                        }
                        ForEach(block.rows) { row in
                            groupRow(row)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    /// "Deselect all" — **the only collective button**, see above. An ``ActionRow``
    /// and not a button of its own: The press does something immediately, and its building block says so.
    private var deselect: some View {
        ActionRow(
            title: "childLock.liveClear",
            icon: Glyph.hidden.name,
            identifier: "live-leeren",
            focus: focus
        ) {
            var fresh = approval
            fresh.clear()
            update(fresh)
        }
        .frame(maxWidth: 900, alignment: .leading)
    }

    /// A group as a ``SwitchRow`` — **"visible for this child" is an on and
    /// off**, and the eye of the building block says exactly that. The channel count is given as wording,
    /// because the sentence below it is a language key and the number is not text.
    private func groupRow(_ row: LivePermission.Row) -> some View {
        SwitchRow(
            wording: LivePermission.caption(row),
            on: Binding(
                get: { row.isAllowed },
                set: { neuerWert in
                    var fresh = approval
                    fresh.set(neuerWert, forItem: row.group)
                    update(fresh)
                }),
            identifier: LivePermission.identifier(row.group),
            focus: focus
        )
        .frame(maxWidth: 900, alignment: .leading)
    }
}
