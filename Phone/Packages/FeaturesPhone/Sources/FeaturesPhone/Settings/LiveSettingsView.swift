import Core
import DesignSystemPhone
import Observation
import PlaylistKit
import SwiftUI

/// Area 3 · Live — **four blocks instead of over three hundred targets.**
///
/// On the TV this one area has more focusable elements than the rest of the app put
/// together: 23 sports in a three-column grid and **four buttons per channel group** with
/// 79 groups. At 393 points that would be a list a thousand points tall. Here four blocks
/// and one onward path remain; the groups get a page of their own with an edit mode
/// (``GroupsView``). **The capability stays complete, the row becomes readable again.**
///
/// **Two switches were dropped on 2026-09-07 because they had no reader outside this view** —
/// "Show preview" and "Show overview before playback". **The second is back since
/// 2026-09-26** (decision 27, C14): since then the Live tab jumps like the TV into the last
/// watched channel, and the switch stops it. The preview stays gone — a running picture in
/// focus does not exist on the phone.
///
/// **Plus the sync of kickoff times** (B6), as on the TV under the schedule filter.
///
/// **Four cards and not three dividers (2026-09-07).** The four blocks hung on `Divider()` rows
/// on the bare background — the same construction that made the root look "rigid and
/// old-fashioned". The footnotes stand **below** their card and not in it: they explain a
/// decision and are not a row.
///
/// **The "Adult channels" switch is NOT here, and that is the most important sentence in
/// this file.** In the draft it appeared twice — once here as a global setting and once in
/// parental controls per account —, without a sentence about which one applies. A parent
/// who switches it off there and later finds it again here does not know whether they have
/// just lifted the lock. It belongs in **one** place, and that is parental controls: only
/// account-bound does it make sense. Here is the row that leads there — with the state in
/// the value column, as the settings root carries it everywhere.
struct LiveSettingsView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    @State private var model: LiveSettingsModel

    /// Leads to group management.
    private let groups: () -> Void
    /// Leads to parental controls — the one place of the adult switch.
    private let parentalControls: () -> Void

    init(
        source: (any ChannelListingSource)? = nil,
        state: ParentalControlsState? = nil,
        groups: @escaping () -> Void = {},
        parentalControls: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: LiveSettingsModel(source: source, state: state))
        self.groups = groups
        self.parentalControls = parentalControls
    }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    liveBlock
                    adults
                    schedule
                    groupsBlock
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .task { await model.load() }
    }

    // MARK: - 1 · The tab itself

    /// **The third reason a tab can be missing — and it says something different from the other
    /// two.** A tab appears if it **exists** (a channel list is set up), if it is **allowed**
    /// (no child mode) and if it is **wanted**. "Live is missing because there is no list" and
    /// "Live is missing because you switched it off" lead to different next steps; that is why
    /// there are three rules and not one.
    @ViewBuilder
    private var liveBlock: some View {
        SettingsCard(header: "tab.live") {
            SwitchRow(
                title: "settings.liveVisible",
                on: .init(get: { model.showsLive }, set: { model.set(showsLive: $0) }))
            SwitchRow(
                title: "settings.liveBrowseToggle",
                on: .init(get: { model.showsOverview }, set: { model.set(overview: $0) }))
        }
        // **The footnote sits below the card and not in it.** It explains the
        // decision, it is not a row — in the box it would look like one that can be
        // pressed. The same split as in ``AboutView``.
        Footnote(message: "settings.live.area.footnote")
        Footnote(message: "live.settings.browseFootnote")
            .padding(.bottom, MetricsBoard.phone.section)
    }

    // MARK: - 2 · Adult channels

    @ViewBuilder
    private var adults: some View {
        SettingsCard(header: "childLock.adult") {
            DisclosureRow(
                title: "settings.kindersicherung", icon: Glyph.kind.name,
                value: model.backupValue, isContained: true, action: parentalControls)
        }
        Footnote(message: "settings.live.adult.footnote")
        Footnote(message: "settings.live.adult.footnote2")
            .padding(.bottom, MetricsBoard.phone.section)
    }

    // MARK: - 3 · Schedule filters

    /// **Chips and not twenty-three switches.** The system switch is the iOS component for a
    /// **capability**, not for membership in a set; twenty-three of them one under another would
    /// be over a thousand points of list for one selection. And later they appear **exactly
    /// like this** above the schedule — whoever ticks them here sees the bar they will get.
    @ViewBuilder
    private var schedule: some View {
        SettingsCard(header: "settings.sportFilters") {
            SwitchRow(
                title: "settings.sportSync",
                on: .init(get: { model.sync.isEnabled }, set: { model.set(sync: $0) }))
            SummaryRow(
                wording: SettingsModel.text(
                    "settings.live.sports.count %lld %lld", model.visibleSports,
                    SportKind.allCases.count),
                all: { model.setAllSports(true) },
                none: { model.setAllSports(false) }
            )
            .padding(.top, MetricsBoard.phone.gutter)

            ChipField(
                entries: SportKind.allCases.map {
                    ChipField.ContentEntryRecord(
                        id: $0.rawValue,
                        caption: SettingsModel.text($0.labelKey),
                        on: model.showsSports($0))
                },
                setEnabled: { identifier in
                    guard let sportKind = SportKind(rawValue: identifier) else { return }
                    model.setEnabled(sport: sportKind)
                }
            )
            .padding(.bottom, Metrics.cardInset)
        }

        Footnote(message: "settings.live.sports.footnote")
        Footnote(message: "live.settings.syncFootnote")
            .padding(.bottom, MetricsBoard.phone.section)
    }

    // MARK: - 4 · Groups

    @ViewBuilder
    private var groupsBlock: some View {
        SettingsCard(header: "live.groups") {
            if model.groupsRead == 0 {
                // **A path that leads nowhere is worse than a sentence.** Before the first visit to the
                // Live area there are no groups; a row with a chevron would lead to an empty list, and
                // that looks like a defect.
                HintRow(
                    icon: Glyph.info.name, title: "settings.live.groups.none",
                    message: "settings.live.groups.none.text")
            } else {
                DisclosureRow(
                    title: "settings.live.groups.manage", icon: Glyph.live.name,
                    value: SettingsModel.text(
                        "settings.live.groups.count %lld %lld", model.groupsRead,
                        model.groupsVisible),
                    isContained: true, action: groups)
            }
        }

        Footnote(message: "settings.liveGroupsHint")
    }
}
