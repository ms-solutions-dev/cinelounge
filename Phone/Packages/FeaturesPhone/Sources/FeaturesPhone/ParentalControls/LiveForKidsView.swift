import Core
import DesignSystemPhone
import ParentalControls
import ProfileKit
import SwiftUI

/// **"Live for children" on the phone — a child's allow list to tick off**
/// (tvOS roadmap AP52, product decision 14 of 2026-09-25).
///
/// **A setting of its own and no mirror of the TV.** The list lives in the
/// device's Keychain and does not travel via iCloud (``ParentalControls/ChannelApproval``)
/// — just like age limit and assignments. What is ticked on the TV applies there;
/// here the choice is made with the channel lists of **this** phone.
///
/// **Behind the door of the parental controls.** The sheet opens only from ``ParentalControlsView``,
/// and that stands behind the PIN — the same place as on the TV.
///
/// **No bulk button "allow all"** — it would be the one press that releases the whole list
/// of a provider, and exactly that this list is not meant to be able to do. Only "deselect
/// all".
struct LiveForKidsView: View {

    /// Wessen Liste.
    let person: Profile

    /// What can be chosen — ``ParentalControls/ChannelApproval/selectable(_:)`` over the
    /// unfiltered catalog.
    let choice: [ChannelApproval.Choice]

    /// The names of the channel lists per identifier — for the headers when there is more than one.
    let listNames: [String: String]

    let state: ParentalControlsState

    var body: some View {
        let approval = state.channelApproval(forItem: person.identifier.rawValue)
        let rows = LivePermission.rows(choice: choice, approval: approval)
        SheetFrame(wording: person.name, message: "childLock.liveListHint") {
            if rows.isEmpty {
                Footnote(message: "childLock.liveNoStock")
            } else {
                DisclosureRow(
                    title: "childLock.liveClear", icon: Glyph.hidden.name,
                    isMissing: false
                ) {
                    state.set(channelApproval: ChannelApproval(), forItem: person.identifier.rawValue)
                }
                ForEach(LivePermission.blocks(rows)) { block in
                    if LivePermission.hasMultipleLists(rows) {
                        SectionHeader(wording: listNames[block.list] ?? block.list)
                    }
                    ForEach(block.rows) { row in
                        SwitchRow(
                            wording: LivePermission.caption(row),
                            on: Binding(
                                get: { row.isAllowed },
                                set: { fresh in
                                    var changed = approval
                                    changed.set(fresh, forItem: row.group)
                                    state.set(
                                        channelApproval: changed,
                                        forItem: person.identifier.rawValue)
                                }))
                    }
                }
            }
        }
    }
}
