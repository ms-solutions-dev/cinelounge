import Core
import CoreGraphics
import DesignSystem
import Testing

@testable import Features

/// Checks the settings of the Live area.
///
/// Two kinds of check are in here: the store — what the viewer sets must
/// survive a restart and must not silently swallow anything from the provider
/// — and the outline of the 79 groups together with the width they occupy.
@Suite("Settings for Live")
@MainActor
struct LiveSettingsTests {

    /// Group names in a real provider's spelling, with invented names.
    ///
    /// Tidy names would be worthless here: the whole effort around prefixes and
    /// superscript characters arises only from these spellings, so the prefixes,
    /// the superscripts and the letters outside ASCII are kept as the provider writes them.
    static let sample = [
        "DE| VELDA ᴿᴬᵂ ⁶⁰ᶠᵖˢ",
        "DE| DEMO ENTERTAINMENT ᴴᴰ ᴰᴼᴸᴮʸ ᴬᵁᴰᴵᴼ",
        "DE| GENERAL HD/4K",
        "TR| SERPEK SPORTS GOLD",
        "TR| MÜZİK 4K",
        "4K| ᵁᴴᴰ ³⁸⁴⁰ᴾ",
        "AT| AUSTRIA HD/4K",
        "CH| SWITZERLAND HD/4K",
        "FOR ADULTS",
    ]

    // MARK: - Adult channels

    @Test("Adult channels stay hidden by default")
    func adultChannelsAreHiddenByDefault() {
        // The case that cannot be undone: on a fresh setup
        // nobody stands at the switch, and whoever pages through 79 groups with the family
        // must not stumble into one. If this test failed, the default would be
        // reversed — and one only notices when it is too late.
        let store = InMemoryStore()

        #expect(LivePreferences.load(from: store).showsAdultChannels == false)
        #expect(LivePreferences().showsAdultChannels == false)
    }

    @Test("The adult channel switch survives both directions")
    func adultSwitchSurvivesBothDirections() {
        // Both directions, because only one of them is written: "on" becomes an
        // entry, "off" a deleted one. If the old entry stayed when switching off,
        // the viewer would have flipped the switch and the channels
        // would be back after the restart — a bug nobody
        // attributes to themselves.
        let store = InMemoryStore()

        var preferences = LivePreferences()
        preferences.setShowsAdultChannels(true)
        preferences.save(to: store)
        #expect(LivePreferences.load(from: store).showsAdultChannels)

        preferences.setShowsAdultChannels(false)
        preferences.save(to: store)
        #expect(LivePreferences.load(from: store).showsAdultChannels == false)
    }

    @Test("A flagged channel stays away while the switch is off")
    func adultChannelStaysAwayWhileSwitchIsOff() {
        // The switch alone is not enough — it must also act on channels whose
        // group is allowed. With a checked access, 294 of 5389 channels
        // carry the marking, and they stand in the middle of allowed groups.
        let preferences = LivePreferences(showsAdultChannels: false)

        #expect(preferences.allows(group: "DE| GENERAL HD/4K", isAdult: true) == false)
        #expect(preferences.allows(group: "DE| GENERAL HD/4K", isAdult: false))
    }

    // MARK: - Hiding groups

    @Test("A newly added group is visible by default")
    func newGroupIsVisibleWithoutAction() {
        // What is stored is what is excluded and not what is allowed. If it were
        // the other way round, groups that the provider adds tomorrow would stay
        // silently invisible — one would then look for the bug in the app or
        // at the provider, and both are the wrong place.
        let store = InMemoryStore()

        var preferences = LivePreferences()
        preferences.setVisible(false, group: "TR| SERPEK SPORTS GOLD")
        preferences.setVisible(false, group: "CH| SWITZERLAND HD/4K")
        preferences.save(to: store)

        let back = LivePreferences.load(from: store)
        #expect(back.allows(group: "TR| SERPEK SPORTS GOLD") == false)
        #expect(back.allows(group: "DE| GANZ NEU ᴴᴰ"))
        #expect(back.hiddenGroups.count == 2)
    }

    @Test("Hidden groups survive the characters in their names")
    func hiddenGroupsSurviveTheirCharacters() {
        // Group names contain everything: vertical bars, colons, commas,
        // slashes, hash signs, superscript characters. Only the newline
        // does not occur, and that is exactly what the store builds on. With a comma as
        // separator, "DE| 24/7 KLASSIKER, INF" would fall into two fragments that match
        // no group — the setting would look set and have no effect.
        let store = InMemoryStore()
        let awkward = [
            "DE| 24/7 KLASSIKER, INF & ³⁸⁴⁰ᴾ",
            "##### PAYTV HEVC #####",
            "4K| RELAX ᵁᴴᴰ ³⁸⁴⁰ᴾ ☼",
        ]

        var preferences = LivePreferences()
        for group in awkward {
            preferences.setVisible(false, group: group)
        }
        preferences.save(to: store)

        let back = LivePreferences.load(from: store)
        #expect(back.hiddenGroups == Set(awkward))
        for group in awkward {
            #expect(back.allows(group: group) == false)
        }
    }

    @Test("A hidden group stays reachable when nothing is loaded")
    func hiddenGroupStaysReachableWithoutLoadedChannels() {
        // Hidden is permanent, loaded is the channel list only when the
        // provider answers. Without the addition from the store, the group would appear in
        // no row, and the viewer would have no way back — they would have to guess
        // that they must first make the access reachable again.
        let rows = LiveSettings.rows(known: [], hidden: ["TR| RADIO MIX"])

        #expect(rows == ["TR| RADIO MIX"])
    }

    @Test("The rows keep the provider's order, the remainder follows")
    func rowsKeepProviderOrder() {
        // The provider's sequence carries information — domestic before foreign. If the
        // loaded groups were sorted along with it, "Zeltkino" would come after "Abendrot". And
        // what arrives from the store must come after that and be sorted,
        // otherwise the list looks different on every call: a set has no
        // order.
        let rows = LiveSettings.rows(
            known: ["DE| VELDA ᴿᴬᵂ ⁶⁰ᶠᵖˢ", "AT| AUSTRIA HD/4K"],
            hidden: ["ZZ| FREMD", "AT| AUSTRIA HD/4K", "AA| FREMD"]
        )

        #expect(rows == ["DE| VELDA ᴿᴬᵂ ⁶⁰ᶠᵖˢ", "AT| AUSTRIA HD/4K", "AA| FREMD", "ZZ| FREMD"])
    }

    // MARK: - Outline in blocks

    @Test("The prefix is the short abbreviation before the dash, otherwise none")
    func prefixIsTheShortHeadOnly() {
        // The length limit is the core: a vertical bar also occurs in the middle of a
        // name. Without it, half the name would be the abbreviation, every group would get
        // its own block, and the outline would become a list with 79
        // header rows — worse than none at all.
        #expect(LiveSettings.prefix(of: "DE| VELDA ᴿᴬᵂ ⁶⁰ᶠᵖˢ") == "DE")
        #expect(LiveSettings.prefix(of: "4K| DEMO SPORT LIVE ⁴ᴷ") == "4K")
        #expect(LiveSettings.prefix(of: "FOR ADULTS") == nil)
        #expect(LiveSettings.prefix(of: "SPORT | PPV EXCLUSIVE") == nil)
        #expect(LiveSettings.prefix(of: "| OHNE") == nil)
        // **Uppercase, so that `de|` and `DE|` are one block** — the same rule as on the phone
        // (``Core/ChannelName/countryCode(fromGroup:)``, AP58 R5).
        #expect(LiveSettings.prefix(of: "de|Sport") == "DE")
    }

    @Test("Every group is in exactly one block, and none appears twice")
    func everyGroupAppearsOnceInOneBlock() {
        // Two blocks with the same abbreviation would be two rows with the same ID.
        // SwiftUI demands unique IDs and, given a duplicate, drops one
        // of the two sets — the groups in it could then no longer be set at all.
        // A lost name would be the same damage.
        let mixed = ["DE| A", "TR| B", "DE| C", "FOR ADULTS", "TR| D"]
        let blocks = LiveSettings.blocks(of: mixed)

        #expect(blocks.map(\.prefix) == ["DE", "TR", ""])
        #expect(blocks.flatMap(\.groups).sorted() == mixed.sorted())
        #expect(Set(blocks.map(\.id)).count == blocks.count)
        #expect(blocks.first?.groups == ["DE| A", "DE| C"])
    }

    @Test("The blocks follow first appearance, nameless ones come last")
    func blocksFollowFirstAppearance() {
        // Sorted alphabetically, "4K" would come before "DE", and the provider's intent
        // — domestic first — would be thrown away. The group without a prefix belongs at the
        // end: mixing it under the first would claim an origin it
        // does not have.
        let blocks = LiveSettings.blocks(of: Self.sample)

        #expect(blocks.map(\.prefix) == ["DE", "TR", "4K", "AT", "CH", ""])
        #expect(blocks.flatMap(\.groups) == Self.sample)
        #expect(blocks.last?.groups == ["FOR ADULTS"])
    }

    // MARK: - Display versus store

    @Test("The readable name is shown, the raw one stored")
    func labelIsReadableWhileStorageStaysRaw() {
        // The expensive mistake would be to store the processed name: `Channel`
        // carries its group raw, a processed name would match not a single
        // channel. The setting would look set, and the hidden channel
        // would stay in the list.
        let raw = "DE| DEMO ENTERTAINMENT ᴴᴰ ᴰᴼᴸᴮʸ ᴬᵁᴰᴵᴼ"

        #expect(LiveSettings.label(for: raw) == "DEMO ENTERTAINMENT HD DOLBY AUDIO")

        var preferences = LivePreferences()
        preferences.setVisible(false, group: raw)
        #expect(preferences.allows(group: raw) == false)
        #expect(preferences.hiddenGroups.contains(raw))
        #expect(preferences.hiddenGroups.contains(LiveSettings.label(for: raw)) == false)
    }

    @Test("Without a prefix the whole name stays")
    func labelKeepsNameWithoutPrefix() {
        // The prefix is dropped only because it appears in the block's header. Where
        // there is none, nothing may be cut off either — a row without a
        // label is a button whose effect one learns only by pressing it.
        #expect(LiveSettings.label(for: "FOR ADULTS") == "FOR ADULTS")
        #expect(LiveSettings.label(for: "DE|") == "DE|")
        #expect(LiveSettings.label(for: "4K| ᵁᴴᴰ ³⁸⁴⁰ᴾ") == "UHD 3840P")
    }

    // MARK: - The section as a whole

    @Test("The Live section is visible at first and can be hidden on its own")
    func liveSectionHidesOnItsOwn() {
        // The Live area also uses the store of the Home rows. That is
        // intended, but requires an ID that belongs to no real row:
        // if it were the same as "Continue Watching", both would disappear together, and
        // nobody would work out the connection.
        let store = InMemoryStore()
        #expect(ShelfPreferences.load(from: store).isVisible(LiveSettings.sectionID))
        #expect(LiveSettings.sectionID != ShelfPreferences.resumeID)

        var shelves = ShelfPreferences()
        shelves.setVisible(false, for: LiveSettings.sectionID)
        shelves.save(to: store)

        let back = ShelfPreferences.load(from: store)
        #expect(back.isVisible(LiveSettings.sectionID) == false)
        #expect(back.isVisible(ShelfPreferences.resumeID))
        // And the Home rows stay as they were — the shared
        // store must not take anything away there.
        #expect(back.arrange([ShelfPreferences.resumeID, "a1b2"]) == [ShelfPreferences.resumeID, "a1b2"])
    }

    @Test("Live is in the outline and has its own icon")
    func liveHasItsOwnSection() {
        // The reason for the separate area was that "Appearance" grew beyond the
        // screen. If the entry were dropped, the switch for adult channels and the 79 groups
        // would not be reachable at all.
        #expect(SettingsSection.allCases.contains(.live))
        #expect(SettingsSection.live.titleKey == "tab.live")

        let symbols = SettingsSection.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count, "two sections with the same icon")
    }

    // MARK: - Screen space

    /// Width of an Apple TV screen in points, as in ``LayoutBudgetTests``.
    static let screen: CGFloat = 1920

    /// What is left for the content of the settings: screen without the sidebar, without
    /// the area list on the left and without the inner padding.
    static var contentWidth: CGFloat {
        screen - AppSidebar.collapsedWidth - SettingsView.sectionListWidth
            - 2 * SettingsView.contentInset
    }

    /// Where the content begins on the left.
    static var contentLeft: CGFloat {
        AppSidebar.collapsedWidth + SettingsView.sectionListWidth + SettingsView.contentInset
    }

    @Test("A row of the group list fits in the content area")
    func groupRowFitsContentColumn() {
        // Content that is too wide is centered on tvOS without any warning and runs
        // out on both sides — on the left under the area list. All that is visible then
        // is a clipped group name, which looks like an edge bug
        // and is a space bug.
        let needed = LiveSettings.rowWidth

        #expect(
            needed <= Self.contentWidth,
            "row \(Int(needed)) points wide, \(Int(Self.contentWidth)) available"
        )
        // Room for the divider between area list and content and for a
        // somewhat wider area list. Fitting to the point tips over at the next
        // change.
        #expect(Self.contentWidth - needed >= 60)
    }

    @Test("The group list stays within the overscan area")
    func groupListStaysInsideOverscan() {
        // To the right of the content, no padding takes care of it by itself: the outer frame
        // ignores the safe area so that the sidebar begins at the screen edge.
        // Outside the 80 points some TVs crop.
        let right = Self.contentLeft + LiveSettings.rowWidth

        #expect(right <= Self.screen - MetricsBoard.tv.margin)
    }

    @Test("Name and switch fit side by side in one row")
    func nameAndToggleFitTheRow() {
        // If it does not fit, the switch slides out of the row instead of the name
        // being shortened — and a switch one cannot see is a group
        // one cannot show.
        let needed = LiveSettings.nameWidth + LiveSettings.columnGap + LiveSettings.toggleWidth

        #expect(needed <= LiveSettings.rowWidth)
    }

    @Test("The longest measured group name fits in its column")
    func longestMeasuredNameFitsItsColumn() {
        // The width of the name column is not a chosen number but a
        // calculation: the longest name of the checked provider — 26 characters
        // once the prefix is dropped — must fit in, otherwise an ellipsis stands there
        // permanently and two groups cannot be told apart.
        //
        // As an approximation 0.6 of the font size per character. Capital letters of the
        // system font lie below that, so the estimate is the unfavorable one.
        let longest = "DE| 24/7 KORA PLUS INF & ³⁸⁴⁰ᴾ"
        let label = LiveSettings.label(for: longest)
        let estimated = CGFloat(label.count) * 25 * 0.6

        #expect(label == "24/7 KORA PLUS INF & 3840P")
        #expect(estimated <= LiveSettings.nameWidth, "\(label) needs \(Int(estimated)) points")
    }

    @Test("The two bulk buttons sit side by side within the row width")
    func bulkButtonsFitSideBySide() {
        // They must overlap horizontally with the rows below: focus
        // moves geometrically on tvOS, and what does not overlap does not reach
        // each other. If the second button lay outside, one could not get from it into
        // the list — and not back from the list.
        let needed = 2 * LiveSettings.bulkButtonWidth + LiveSettings.columnGap

        #expect(needed <= LiveSettings.rowWidth)
    }
}
