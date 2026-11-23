import DesignSystemPhone
import SwiftUI

/// Two switches and a footnote — **as a block of the ``ParentalControlsView``, not as
/// a screen of its own.**
///
/// **It stood once too often, and the draft says why.** "Show adult channels"
/// was drawn as a global setting under `Settings → Live` **and** a second
/// time per account in the parental controls — two switches for the same matter, without
/// a sentence about which applies. A parent who turns it off there and later finds it
/// here again does not know whether they have just lifted the lock. A first version
/// of this package built a standalone view next to it; in the end it was
/// reachable from nowhere — a screen that nobody can open is none.
///
/// **It belongs in exactly one place, and that is the parental controls:** only per
/// account does it make sense. Under `Settings → Live` therefore stands the **row that leads
/// there**, with the state in the value column.
///
/// **The footnote explains why there are two switches: an M3U list has no
/// labeling.** Xtream carries `is_adult` — with the provider checked, 294 of 5,389
/// channels are labeled that way —, an M3U list has no field for it at all. A
/// switch relying on a labeling that does not exist there would be a
/// promise; that is why next to it it says what it does there: **nothing**.
///
/// **The second switch is explicitly switchable off, and its default is "off".** That
/// is the reverse of the first default, and the reason is the direction of the surprise:
/// a channel that slipped through is a nuisance, an empty channel list looks like a
/// defect — and it occurs immediately with every pure M3U list.
struct AdultChannelBlock: View {

    let state: ParentalControlsState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "childLock.adult")

            SwitchRow(
                title: "childLock.adult.show",
                on: .init(
                    get: { state.channelLock.showsAdult },
                    set: { state.set(showsAdult: $0) }))

            SwitchRow(
                title: "childLock.adult.hideUnmarked", message: "childLock.adult.hideUnmarked.text",
                on: .init(
                    get: { state.channelLock.hidesUnlabeled },
                    set: { state.set(hidesUnlabeled: $0) }))

            Footnote(message: "childLock.adult.footnote")

            // **The second finding, without sugarcoating.** It stands as a row of its own and
            // not in the footnote: whoever relies on the labeling should know
            // that for one half of their lists it does not exist at all.
            HintRow(
                icon: Glyph.warning.name, color: ColorRole.progress.color,
                title: "childLock.adult.m3u", message: "childLock.adult.m3u.text")
        }
    }
}
