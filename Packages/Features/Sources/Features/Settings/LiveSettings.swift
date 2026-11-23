import Core
import DesignSystem
import SwiftUI

/// What the Live area shows: the area itself, the adult channels, the
/// groups.
///
/// **Why a separate area.** These three settings first lived under
/// "Appearance", between language and the Home rows. With 79 groups the
/// page there is taller than the screen, and you scroll past everything
/// you are not looking for — exactly the state ``SettingsSection`` was built against. One
/// more area in the list on the left costs nothing; a page that keeps growing costs
/// something on every use.
///
/// **The group names come from outside.** This view queries no provider:
/// the Live area already holds the loaded collection, and a second fetch would mean,
/// on an account with `max_connections 1`, nine megabytes a second time — over
/// a tunnel with a measured 0.3 Mbit/s a matter of minutes.
struct LiveSettings: View {

    /// The group names **in the provider's order**, raw as delivered.
    ///
    /// Raw, not processed: the raw name is stored because ``Channel``
    /// carries it that way. It is made readable only at draw time, see ``label(for:)``.
    let groups: [String]

    @State private var preferences = LivePreferences()
    @State private var isSectionVisible = true
    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    /// Opens the "Parental controls" area — **the area list decides whether it can.**
    ///
    /// The default is empty so the checks can build this view without an environment; in the
    /// app ``SettingsView`` passes the path in together with the door.
    var openParentalControls: () -> Void = {}

    // MARK: - Dimensions
    //
    // As constants and not as bare numbers in the body, so they can be recomputed:
    // `LiveSettingsTests` checks that the row fits its width
    // and the list stays within the overscan area. Content that is too wide is centred on tvOS
    // without a warning and overflows on both sides.

    /// Width of a row in the group list, like the Home rows under
    /// "Appearance" — both lists are in the same area and should line up.
    static let rowWidth: CGFloat = 900
    /// What is left for the group name. The rest of the row belongs to the switch.
    static let nameWidth: CGFloat = 620
    /// **Since AP26 (row building blocks) from ``SettingsMetrics``.** The width calculation of the
    /// row still reads it here — this is the only place that needs it.
    static let toggleWidth = SettingsMetrics.iconButton.width
    static let columnGap: CGFloat = 18
    /// Fixed width for the bulk buttons, so the calculation holds and does not depend on
    /// the length of the translation.
    static let bulkButtonWidth: CGFloat = 340

    /// The identifier of the Live area in ``ShelfPreferences``.
    ///
    /// The same store as for the Home rows, on purpose: the question is
    /// the same — what appears in the menu and on Home. A second store
    /// for the same question would sooner or later drift apart, and then it is no
    /// longer possible to say which one applies.
    ///
    /// The value must not collide with any library identifier of the server; those are
    /// ID numbers in hexadecimal notation, `live` is not one.
    static let sectionID = "live"

    /// Whether the overview, the group list or the sports are currently open.
    ///
    /// **The tab bar ("General · Sports · Groups") was removed on 2026-09-25.** It
    /// jumped to blocks of a long page; since the groups (2026-09-24) and the sports
    /// (2026-09-25) each sit behind a single row, it appeared in the group list and pointed at
    /// targets that were no longer there — a press with no effect.
    ///
    /// **The list is the reason this area had ninety focus targets** (AP46,
    /// 2026-09-24): a provider brings **79 groups**, and each was a row on the
    /// **first** level. A tab bar was built against that on 2026-09-12. ("from over ninety
    /// presses to two") — that helped with reaching them and does not change the count.
    ///
    /// **The same pattern as "Appearance"** (``OtherSettings``): one mode, one way back
    /// via the Menu button. The roadmap demands exactly that — "the existing mode pickers
    /// remain the target screens".
    private enum Mode {
        case overview, groups
        /// The sports of the schedule (AP46, 2026-09-25) — ten or more switches that
        /// sat on the first level above the limit of the done condition.
        case sport
    }

    @State private var mode: Mode = .overview

    var body: some View {
        switch mode {
        case .overview: overview
        case .groups:
            groupList
                .backWithMenu {
                    mode = .overview
                    focus = "gruppen-auf"
                }
        case .sport:
            sports
                .onAppear { focus = SportKind.allCases.first.map { "sportfilter-" + $0.rawValue } }
                .backWithMenu {
                    mode = .overview
                    focus = "sport-auf"
                }
        }
    }

    @ViewBuilder
    private var overview: some View {
        VStack(alignment: .leading, spacing: 46) {
            sectionVisibility
            browseArea
            adultChannels
            channelPreview
            sportFilters
            groupRow
        }
        .task { reload() }
        .task { await countAdultChannels() }
        .preference(key: SettingsFirstEntryKey.self, value: "visible")
        .onChange(of: entryRequest) { _, _ in focus = "visible" }
    }

    /// **The row behind which the 79 groups sit** — with its count.
    ///
    /// **The value is half the information** (AP46): "46 of 79" answers the question for which
    /// you would otherwise have to go inside. A row with a name and a chevron required a
    /// press to find out whether anything is hidden at all.
    @ViewBuilder
    private var groupRow: some View {
        let all = Self.rows(known: groups, hidden: preferences.hiddenGroups)
        if !all.isEmpty {
            let state = AppLanguageSetting.text("settings.live.groupCount \(visibleGroups) \(all.count)")
            VStack(alignment: .leading, spacing: 0) {
                SettingsHeader("live.groups", hint: "settings.liveGroupsHint")
                DisclosureRow(
                    title: "settings.liveGroupsOpen",
                    value: state,
                    card: CardSpec(
                        header: "settings.liveGroupsOpen",
                        statementWording: state,
                        explanation: "settings.liveGroupsHint",
                        pills: Self.lookahead(all, hidden: preferences.hiddenGroups),
                        optionCount: all.count,
                        // **On the device and not on the person**, because `hiddenGroups` lives in
                        // the device settings. The label says what the code
                        // does — not what would be nice: a promise of "moves with you" that
                        // has no store behind it would be exactly the badge error that
                        // AP46 already fixed once at the age limit.
                        validity: .profile),
                    identifier: "gruppen-auf",
                    focus: $focus
                ) {
                    mode = .groups
                }
            }
        }
    }

    /// How many groups the card shows as pills.
    ///
    /// **Four, because the card is 480 points wide.** A pill with an
    /// average group name needs about 200 points including padding at 27 pt —
    /// four make two rows, and that is a preview. Eight would be four rows and
    /// thus the second list this package is built against.
    nonisolated static let previewCount = 4

    /// The preview for the card: the **first** groups of the list with their state.
    ///
    /// **The start of the list and not a selection from it.** Showing only the visible ones
    /// would mean withholding half of the statement — the preview is meant precisely to
    /// show that filled means "visible" and outlined means "hidden". And showing only the
    /// hidden ones would be an error list where there are no errors.
    ///
    /// **As a calculation and not in the `body`**, so ``GroupRowTests`` can recompute it:
    /// that a hidden group appears as an outlined pill is the
    /// actual statement of the preview.
    nonisolated static func lookahead(_ all: [String], hidden: Set<String>) -> [CardPill] {
        all.prefix(previewCount).map { CardPill($0, chosen: !hidden.contains($0)) }
    }

    private var visibleGroups: Int {
        Self.visible(known: groups, hidden: preferences.hiddenGroups)
    }

    /// How many groups appear in the menu.
    ///
    /// **As a calculation and not as a property of the view**, so the number can be checked:
    /// a test suite that recomputes it itself in the test checks its own calculation. Exactly
    /// this slip happened to me several times on 2026-09-24.
    ///
    /// **Hidden ones do not count as visible and still do not drop out of the list** (see
    /// ``rows(known:hidden:)``) — otherwise they could no longer be switched on.
    nonisolated static func visible(known: [String], hidden: Set<String>) -> Int {
        rows(known: known, hidden: hidden).count { !hidden.contains($0) }
    }

    // MARK: - Counting adult channels

    /// The channel catalog the count is taken from.
    var stock: @Sendable () async -> [Channel] = { [] }

    /// What the count produced: flagged channels, all channels, the groups
    /// of the flagged ones (the largest first).
    @State private var adultTally: (marked: Int, total: Int, groups: [String])?

    private func countAdultChannels() async {
        let channels = await stock().filter { !$0.isSectionMarker }
        let marked = channels.filter(\.isAdult)
        var perGroup: [String: Int] = [:]
        for channel in marked { perGroup[channel.group ?? "—", default: 0] += 1 }
        let groups = perGroup.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(4).map { "\($0.key) (\($0.value))" }
        adultTally = (marked.count, channels.count, groups)
    }

    /// What the parental controls row shows — **"visible" or "hidden" and
    /// not "on" or "off"** (AP46, 2026-09-25). The row is called "Open in parental
    /// controls"; an "off" next to it would read as "parental controls are off" — the
    /// opposite of what is meant. **A forward row and not a bulk button:** the
    /// press leads to another area, and that is exactly what the arrow says.
    nonisolated static func adultState(_ isVisible: Bool) -> String {
        isVisible ? "settings.live.a11y.visible" : "settings.live.a11y.hidden"
    }

    /// The line under the switch: what the own lists yield — not
    /// what a checked provider once had (user question 2026-09-04: "where exactly
    /// are these 294?" — on this account nowhere).
    @ViewBuilder
    private var adultTallyLine: some View {
        if let tally = adultTally {
            if tally.marked == 0 {
                Text(app: "settings.liveAdultNone \(tally.total)")
            } else {
                Text(
                    app:
                        "settings.liveAdultCount \(tally.marked) \(tally.total) \(tally.groups.joined(separator: ", "))"
                )
            }
        }
    }

    // MARK: - The area as a whole

    /// Show or hide Live entirely.
    ///
    /// Sits at the very top because it is the precondition for everything else. When hidden,
    /// the entry disappears from the sidebar; the entered channel lists
    /// remain, otherwise you would have to retype address and access — on tvOS the
    /// most expensive operation of all.
    ///
    /// The settings below remain usable anyway. A page that loses half of its rows
    /// when toggled jumps away under the focus, and
    /// you then press something other than intended.
    ///
    /// **Freshly loaded, changed, written.** The store is shared with the
    /// order of the Home rows under "Appearance"; whoever writes from an old copy
    /// silently reverts a change made there.
    ///
    /// **Since 2026-09-25 a ``SwitchRow``** and no longer a pill (AP46): the
    /// four switches of this area looked like a choice among siblings.
    private var sectionVisibility: some View {
        VStack(alignment: .leading, spacing: 0) {

            SwitchRow(
                title: "settings.liveVisible",
                on: Binding(
                    get: { isSectionVisible },
                    set: { fresh in
                        var shelves = ShelfPreferences.load(from: FileStore(), forItem: ProfilePointer.active)
                        shelves.setVisible(fresh, for: Self.sectionID)
                        shelves.save(to: FileStore(), forItem: ProfilePointer.active)
                        isSectionVisible = shelves.isVisible(Self.sectionID)
                    }),
                card: .toggle(
                    header: "settings.liveVisible", on: isSectionVisible, explanation: nil,
                    validity: .profile),
                identifier: "visible",
                focus: $focus)
        }
    }

    // MARK: - Adult channels

    /// The switch for channels flagged as adult content.
    ///
    /// **The explanatory text matters more than the switch.** A switch that
    /// is called "Hide adult channels" and says nothing else promises a
    /// safety it cannot keep: the flag comes from the provider.
    /// Whoever knows that checks for themselves; whoever does not know believes they are safe
    /// and is worse off than before.
    /// The switch for the preview.
    ///
    /// Sits with the channels and not under "Appearance" because it is not merely a
    /// question of looks: the preview occupies a connection at the provider. The
    /// note below says so instead of passing it off as a matter of taste — whoever has only
    /// one connection should know what they are getting into.
    private var channelPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("settings.livePreview", hint: "settings.livePreviewHint")

            SwitchRow(
                title: "settings.livePreviewToggle",
                on: Binding(
                    get: { preferences.previewsChannels },
                    set: { fresh in
                        preferences.setPreviewsChannels(fresh)
                        preferences.save(to: ProfileStore.playback)
                    }),
                card: .toggle(
                    header: "settings.livePreviewToggle", on: preferences.previewsChannels,
                    explanation: "settings.livePreviewHint", validity: .profile),
                identifier: "preview",
                focus: $focus)
        }
    }

    /// The switch for the overview area.
    ///
    /// **Sits at the very top because it decides the path** and is not merely a
    /// detail within it: when it is off, a press on "Live" leads straight into
    /// the last watched channel.
    ///
    /// It is deliberately not called "Preview" — that is the switch below, and
    /// it means something quite different (the running picture in focus, which occupies a
    /// connection at the provider). Two switches with the same word would be
    /// a trap.
    private var browseArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("settings.liveBrowse", hint: "settings.liveBrowseHint")

            SwitchRow(
                title: "settings.liveBrowseToggle",
                on: Binding(
                    get: { preferences.showsBrowseArea },
                    set: { fresh in
                        preferences.setShowsBrowseArea(fresh)
                        preferences.save(to: ProfileStore.playback)
                    }),
                card: .toggle(
                    header: "settings.liveBrowseToggle", on: preferences.showsBrowseArea,
                    explanation: "settings.liveBrowseHint", validity: .profile),
                identifier: "browse",
                focus: $focus)
        }
    }

    private var adultChannels: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("childLock.adult", hint: "settings.liveAdultHint")

            // **The switch is no longer here but in the parental controls**
            // (G3). This is the most serious finding of the phone pass, adopted: there,
            // four taps led from the child account to here — without a PIN. A switch
            // behind a door and next to it a copy without a door is not a lock.
            //
            // **What stays is the row that says where it is.** Removing it without
            // replacement would mean hiding it; whoever looked for it here would otherwise keep
            // looking.
            Text(app: "settings.liveAdultMoved")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.vertical, 14)

            // **A reference without a path is a dead end** (AP23, 2026-09-11). This
            // block was pure text without a single focus target, sandwiched between
            // `browse` above and `channelPreview` below: whoever wanted to follow the sentence
            // had to find the area list by hand. ``DiagnosticsSettings`` had the same
            // disease with the log list, and there it is
            // already fixed.
            //
            // **The button carries no second lock.** It switches the area, and
            // the door in front of it is the same one the area list sets — it sits in
            // ``SettingsView`` and is passed through here. A check of its own at
            // this point would be a second rule for the same question.
            DisclosureRow(
                title: "settings.liveAdultOpen",
                value: PlaybackSettings.word(Self.adultState(preferences.showsAdultChannels)),
                card: CardSpec(
                    header: "childLock.adult",
                    statement: Self.adultState(preferences.showsAdultChannels),
                    explanation: "settings.liveAdultHint", validity: .profile),
                identifier: "adult-open",
                focus: $focus
            ) {
                openParentalControls()
            }
            .padding(.top, 18)

            // **The youth-protection note is no accessory** (AP5 · B7): it
            // says what the switch above relies on — and someone then
            // decides for their family. `caption2` sits at 18.2
            // arcminutes, our own lower limit, and `textFaint` is the
            // weakest colour of the palette.
            adultTallyLine
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.text.color)
                .padding(.top, 22)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)

            Text(app: "settings.liveAdultTrust")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
        }
    }

    // MARK: - Groups

    /// The groups, block by block by the provider's prefix.
    /// The ticked groups — hiding and moving then act on
    /// all of them at once.
    /// Which sports chips the schedule shows (user request 2026-08-16).
    @State private var sportFilterSettings = SportFilterSettings.load(from: ProfileStore.playback)
    @State private var sportSyncSettings = SportSyncSettings.load(from: SecureStore())

    /// The filter choice of the schedule — above the groups, as requested:
    /// whoever watches only football and basketball switches off the rest. "All"
    /// and the star always stay; switched-off sports are missing from the chip bar
    /// **and from the list** (decision 4 of the sports concept, 2026-09-02) — on both
    /// devices under the same key (``Core/SportFilterSettings``, AP58 R5).
    private var sportFilters: some View {
        VStack(alignment: .leading, spacing: SettingsView.entrySpacing) {
            SettingsHeader("settings.sportFilters", hint: "settings.sportFiltersHint")

            // The match against the online kick-off source — can be switched off for
            // everyone who wants no requests to a third-party source.
            SwitchRow(
                title: "settings.sportSync",
                on: Binding(
                    get: { sportSyncSettings.isEnabled },
                    set: { fresh in
                        sportSyncSettings.isEnabled = fresh
                        sportSyncSettings.save(to: SecureStore())
                    }),
                card: .toggle(
                    header: "settings.sportSync", on: sportSyncSettings.isEnabled,
                    explanation: nil, validity: .device),
                identifier: "sport-sync",
                focus: $focus)

            let state = AppLanguageSetting.text(
                "settings.homeShownOf \(SportKind.allCases.count { sportFilterSettings.isEnabled($0) }) \(SportKind.allCases.count)"
            )
            DisclosureRow(
                title: "settings.sportKinds",
                value: state,
                card: CardSpec(
                    header: "settings.sportKinds",
                    statementWording: state,
                    explanation: "settings.sportFiltersHint",
                    validity: .profile),
                identifier: "sport-auf",
                focus: $focus
            ) {
                mode = .sport
            }
        }
    }

    /// The sports as switches — **the second level behind ``sportFilters``.**
    ///
    /// Three columns instead of a flood of rows (user request 2026-08-16: "the page gets extremely
    /// long, there is a lot of empty space on the right"). A fixed number, no device detection: tvOS
    /// draws the same 1920×1080 points on every TV.
    private var sports: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("settings.sportKinds", hint: "settings.sportFiltersHint")
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 28, alignment: .leading),
                    count: 3),
                alignment: .leading, spacing: 6
            ) {
                ForEach(SportKind.allCases, id: \.rawValue) { kind in
                    checkButton(
                        titleKey: kind.labelKey,
                        id: "sportfilter-" + kind.rawValue,
                        isOn: sportFilterSettings.isEnabled(kind)
                    ) {
                        sportFilterSettings.toggle(kind)
                        sportFilterSettings.save(to: ProfileStore.playback)
                    }
                }
            }
        }
        .focusSection()
    }

    @State private var selection: Set<String> = []

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("live.groups", hint: "settings.liveGroupsHint")

            let rows = preferences.ordered(
                Self.rows(known: groups, hidden: preferences.hiddenGroups))

            if rows.isEmpty {
                Text(app: "settings.liveGroupsUnknown")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900, alignment: .leading)
            } else {
                bulkActions(over: rows)

                // All rows in **one** VStack: on tvOS the focus moves
                // geometrically and reliably only between siblings. Putting blocks in
                // containers of their own would mean the jump from the last
                // row of one block to the header of the next is left to the luck of the
                // hit test.
                VStack(spacing: 0) {
                    ForEach(Self.blocks(of: rows)) { block in
                        blockHeader(block)
                        ForEach(block.groups, id: \.self) { name in
                            groupRow(name)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    /// "Show all" and "hide all".
    ///
    /// **Why bulk buttons at all:** 46 of the 79 groups of a checked account
    /// are German, the other 33 in languages the owner does not speak. Whoever
    /// pushes those away one by one presses 33 times — that is not usable.
    ///
    /// **Why no "German only" button:** it would have to guess what is German. The
    /// prefix `DE|` is a habit of this provider, not a guarantee; with
    /// another one the button would silently hit nothing or the wrong thing. Instead
    /// every header acts on its whole block: "all off", then `DE` on — two
    /// actions, and they visibly do what they say.
    private func bulkActions(over rows: [String]) -> some View {
        HStack(spacing: Self.columnGap) {
            bulkButton(titleKey: "settings.liveGroupsShowAll", id: "bulk-show") {
                setVisible(true, groups: rows)
            }
            bulkButton(titleKey: "settings.liveGroupsHideAll", id: "bulk-hide") {
                setVisible(false, groups: rows)
            }
        }
        .frame(maxWidth: Self.rowWidth, alignment: .leading)
    }

    /// The header of a block: abbreviation, count, switch for the whole block.
    ///
    /// The count is shown as a pair of numbers and not as a sentence. "12/46" needs
    /// no translation and is faster to grasp from three metres away than
    /// "12 of 46 visible" — and it is the information missing when paging through 79
    /// rows: where you are and what you just did.
    private func blockHeader(_ block: GroupBlock) -> some View {
        let visible = block.groups.filter { preferences.allows(group: $0) }.count
        let id = "block-" + block.id

        return HStack(spacing: Self.columnGap) {
            if block.prefix.isEmpty {
                Text(app: "settings.liveGroupsOther")
            } else {
                Text(verbatim: block.prefix)
            }

            Text(verbatim: "\(visible)/\(block.groups.count)")
                .foregroundStyle(ColorRole.textMatt.color)

            Spacer(minLength: 0)

            // One switch for the whole block: if anything in it is visible,
            // it hides everything, otherwise it shows everything. "Half visible" as a third
            // state would not be recognisable on a TV — that is what the
            // count next to it is for.
            toggleButton(
                symbol: visible > 0 ? Glyph.isVisible.name : Glyph.hidden.name,
                id: id,
                label: "settings.live.a11y.blockVisibility",
                state: visible > 0 ? "settings.live.a11y.visible" : "settings.live.a11y.hidden"
            ) {
                setVisible(visible == 0, groups: block.groups)
            }
        }
        .font(TypeLevel.header.font)
        .foregroundStyle(ColorRole.text.color)
        .padding(.top, 34)
        .padding(.bottom, 10)
        .frame(maxWidth: Self.rowWidth, alignment: .leading)
        // Full row width as a focus section — the switch sits at the far right
        // and was outside the search cone: from "Show all" you could
        // not get down into the blocks (on-device finding 2026-08-08, the same
        // disease as with the channel list rows).
        .focusSection()
    }

    private func groupRow(_ name: String) -> some View {
        let visible = preferences.allows(group: name)
        let checked = selection.contains(name)

        return HStack(spacing: Self.columnGap) {
            // The checkbox: whoever wants to hide or move several groups at once
            // ticks them — eye and arrows then act
            // on the whole selection (user request 2026-08-08).
            toggleButton(
                symbol: Glyph.checkbox.pair.forItem(checked),
                id: "check-" + name,
                label: "common.select",
                state: checked ? "settings.live.a11y.selected" : "settings.live.a11y.unselected"
            ) {
                if checked {
                    selection.remove(name)
                } else {
                    selection.insert(name)
                }
            }

            Text(verbatim: Self.label(for: name))
                .font(TypeLevel.footer.font)
                .foregroundStyle(visible ? ColorRole.text.color : ColorRole.textQuiet.color)
                .lineLimit(1)
                .frame(width: Self.nameWidth, alignment: .leading)

            Spacer(minLength: 0)

            // Moving changes the order everywhere: in the area itself,
            // in the sidebar and here. If the row is part of the selection,
            // the whole selection moves.
            toggleButton(
                symbol: "arrow.up", id: "up-" + name,
                label: "settings.live.a11y.moveUp"
            ) {
                move(name, by: -1)
            }
            toggleButton(
                symbol: "arrow.down", id: "down-" + name,
                label: "settings.live.a11y.moveDown"
            ) {
                move(name, by: 1)
            }

            toggleButton(
                symbol: visible ? Glyph.isVisible.name : Glyph.hidden.name,
                id: "group-" + name,
                label: "settings.live.a11y.visibility",
                state: visible ? "settings.live.a11y.visible" : "settings.live.a11y.hidden"
            ) {
                // Part of the selection: the press applies to all ticked ones — otherwise
                // ticking would be a promise without effect.
                let targets = checked && selection.count > 1 ? Array(selection) : [name]
                setVisible(!visible, groups: targets)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: Self.rowWidth, alignment: .leading)
        // The same reasoning as at the block header.
        .focusSection()
        .overlay(alignment: .bottom) {
            Rectangle().fill(ColorRole.lineQuiet.color).frame(height: 1)
                // Decoration otherwise takes part in the hit test and blocks the
                // focus of the row below. This error has already occurred in the project
                // four times.
                .allowsHitTesting(false)
        }
    }

    /// Moves a row — or the whole selection if it belongs to it.
    ///
    /// **Classic block moving:** when moving up, the selected
    /// rows move from top to bottom one place each, when moving down
    /// from bottom to top — whoever is at the edge stays put, and the selection
    /// stays together as a block. The FULL row order is stored:
    /// from now on it is the viewer's order.
    private func move(_ name: String, by offset: Int) {
        var rows = preferences.ordered(
            Self.rows(known: groups, hidden: preferences.hiddenGroups))
        let moving: Set<String> =
            selection.contains(name) ? selection : [name]

        let indices = rows.indices.filter { moving.contains(rows[$0]) }
        let ordered = offset < 0 ? indices : indices.reversed()

        for index in ordered {
            let target = index + offset
            guard rows.indices.contains(target), !moving.contains(rows[target]) else { continue }
            rows.swapAt(index, target)
        }

        preferences.setGroupOrder(rows)
        preferences.save(to: ProfileStore.playback)
    }

    // MARK: - Buttons

    /// Checkmarks instead of sliders — for the same reason as with the libraries
    /// for the header area: from three metres away a slider cannot be recognised as
    /// on or off.
    private func checkButton(
        titleKey: String,
        id: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == id

        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                Text(appKey: titleKey)
            }
            .font(TypeLevel.footer.font)
            .settingsFont(isFocused: isFocused, muted: !isOn)
            .settingsSurface(
                .pill, isFocused: isFocused,
                reason: isOn ? ColorRole.surface.color : ColorRole.surfaceHigh.color)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        // Siehe ``OtherSettings/smallButton(_:id:enabled:action:)`` — dieselbe
        // Elementart, derselbe Faktor (AP26).
        .focusHighlight(focus == id, scale: Tokens.Focus.buttonScale)
        .info(appKey: titleKey, .on(isOn))
    }

    private func bulkButton(
        titleKey: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == id

        return Button(action: action) {
            Text(appKey: titleKey)
                .font(TypeLevel.footer.font)
                .settingsFont(isFocused: isFocused, muted: true)
                .lineLimit(1)
                .settingsSurface(.pill, isFocused: isFocused, width: Self.bulkButtonWidth)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
    }

    /// - Parameters:
    ///   - beschriftung: What this button **does** — as a language key.
    ///   - zustand: What currently **applies**, if the button carries a state.
    ///
    /// **The label sits at the factory and not on three hundred buttons** (AP26,
    /// 2026-09-11). In `Settings/` there were **zero** `accessibilityLabel`s; all four buttons
    /// per group row come out of here, so one parameter covers them all.
    ///
    /// **And the state belongs with it**, not just the action: `eye` versus `eye.slash`
    /// at 22 pt is guesswork from three metres — for the screen reader it is nothing at all. What
    /// a button toggles is only told by the pair of label and value.
    private func toggleButton(
        symbol: String,
        id: String,
        label: String,
        state: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == id

        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .settingsFont(isFocused: isFocused, muted: true)
                .settingsSurface(.character, isFocused: isFocused)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .focusHighlight(isFocused, scale: Tokens.Focus.buttonScale)
        .info(appKey: label, .key(state))
    }

    // MARK: - Changing

    private func setVisible(_ visible: Bool, groups: [String]) {
        for name in groups {
            preferences.setVisible(visible, group: name)
        }
        preferences.save(to: ProfileStore.playback)
    }

    private func reload() {
        preferences = LivePreferences.load(from: ProfileStore.playback)
        isSectionVisible = ShelfPreferences.load(from: FileStore(), forItem: ProfilePointer.active).isVisible(
            Self.sectionID)
    }

    // MARK: - Structure of the group list

    /// A block of the group list: all groups with the same prefix.
    struct GroupBlock: Identifiable, Equatable {
        /// The abbreviation, or empty for groups without a prefix.
        let prefix: String
        let groups: [String]

        var id: String { prefix }
    }

    /// The abbreviation before the vertical bar, or nothing — the rule is in
    /// ``Core/ChannelName/countryCode(fromGroup:)`` and applies on the phone just the same (AP58 R5,
    /// finding L2).
    static func prefix(of name: String) -> String? {
        ChannelName.countryCode(fromGroup: name)
    }

    /// Groups the groups by their prefix.
    ///
    /// The blocks follow **first occurrence** and not the alphabet — the same
    /// reasoning as with ``LiveLibrary/groups(from:)``: the provider sorts
    /// on purpose, domestic before foreign. On a checked account the groups
    /// already sit together by abbreviation, so the blocks coincide there with its order.
    /// Where it mixes them, the block wins: a header that acts on its
    /// block must have it completely beneath it.
    ///
    /// Groups without a prefix go into a block at the end. Mixing them in among the first ones
    /// would give false information about their origin.
    static func blocks(of names: [String]) -> [GroupBlock] {
        var order: [String] = []
        var buckets: [String: [String]] = [:]
        var loose: [String] = []

        for name in names {
            guard let key = prefix(of: name) else {
                loose.append(name)
                continue
            }
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(name)
        }

        var result = order.map { GroupBlock(prefix: $0, groups: buckets[$0] ?? []) }
        if !loose.isEmpty {
            result.append(GroupBlock(prefix: "", groups: loose))
        }
        return result
    }

    /// The rows of the list: the existing groups, plus hidden ones that
    /// are not currently loaded.
    ///
    /// The addendum is no accessory but the way back. Hiding is stored
    /// permanently, whereas the channel list is loaded only when the provider
    /// is currently answering. Without the addendum, a group you have hidden
    /// could no longer be shown again with a silent provider — and its absence would look
    /// like an error of the app.
    ///
    /// The addendum is sorted so the list looks the same when called twice;
    /// a set has no order.
    /// **nonisolated because it is a pure calculation** (2026-09-24): two lists
    /// in, one out, no state. Without that, sichtbare(known:hidden:) could not
    /// call it without running into the main actor itself — and the build reported a
    /// warning that is an error in the release build.
    nonisolated static func rows(known: [String], hidden: Set<String>) -> [String] {
        known + hidden.subtracting(known).sorted()
    }

    /// The group name as it appears in the row.
    ///
    /// Two interventions. ``ChannelName/display(_:)`` folds the superscript characters
    /// — group names carry them too, `DE| VELDA ᴿᴬᵂ ⁶⁰ᶠᵖˢ` for example. And the prefix
    /// is dropped because it already stands in the block header; repeating it 46 times
    /// below eats the width the name itself needs.
    ///
    /// **Display only.** The raw name is always what is stored and compared:
    /// ``Channel`` carries it raw, and a processed one would not match a single
    /// channel when filtering — the setting would look right and have no effect.
    static func label(for name: String) -> String {
        let readable = ChannelName.display(name)

        guard prefix(of: name) != nil, let cut = readable.firstIndex(of: "|") else {
            return readable
        }

        let rest = readable[readable.index(after: cut)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? readable : rest
    }
}
