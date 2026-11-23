import Core
import CoreGraphics
import DesignSystem
import Foundation
import PlaylistKit
import Testing

@testable import Features

/// Checks the Live area without a provider, without a network and without a TV.
///
/// **Why this test suite is not negotiable:** The access this area depends on
/// expires, allows a single connection and blocks the address
/// after too many requests. Whatever is not recalculated here without it is not
/// recalculated at all — it gets noticed on the TV or never.
///
/// The numbers in the explanations come from a recorded catalog: 5389
/// channels in 79 groups, of which 113 entries are not channels, 294
/// adult channels, 1313 names with a provider prefix and 2176 with superscript
/// characters.
@Suite("Live section")
@MainActor
struct LiveModelTests {

    // MARK: - Setup

    private static func channel(
        _ id: String,
        _ name: String,
        group: String? = nil,
        epgID: String? = nil,
        isAdult: Bool = false,
        isFavorite: Bool = false,
        suffix: String = "ts"
    ) -> Channel {
        Channel(
            id: id,
            name: name,
            streamURL: URL(string: "http://anbieter.example/live/user/pass/\(id).\(suffix)")!,
            playlistID: "liste",
            group: group,
            epgID: epgID,
            isFavorite: isFavorite,
            isAdult: isAdult
        )
    }

    /// A catalog that reproduces the quirks of the real one in miniature: two
    /// groups in the provider's order, a heading in the middle, an
    /// adult channel and a name with a prefix and superscript characters.
    private static func stock() -> [Channel] {
        [
            channel("1", "DE| DAS NORDLICHT ᴴᴰ", group: "DE Vollprogramme", epgID: "ahorn.de"),
            channel("2", "##### SOLA HEVC #####", group: "DE Vollprogramme"),
            channel("3", "DE| WELLE ENTERTAINMENT ᴴᴰ ᴰᴼᴸᴮʸ ᴬᵁᴰᴵᴼ", group: "DE Vollprogramme"),
            channel("4", "TR: TELVE 1", group: "TR Genel", epgID: "telve1.tr"),
            channel("5", "XXX Night Channel", group: "For Adults", isAdult: true),
        ]
    }

    private static func model(
        preferences: LivePreferences = LivePreferences(),
        channels: [Channel] = LiveModelTests.stock(),
        guide: @escaping @Sendable (Channel) -> [Programme] = { _ in [] },
        setFavorite: @escaping @MainActor (Channel, Bool) -> Void = { _, _ in }
    ) -> LiveModel {
        LiveModel(
            preferences: preferences,
            stock: { LiveModel.Stock(channels: channels) },
            guide: { guide($0) },
            setFavorite: setFavorite,
            // No waiting time: a check that sleeps for half a second gets switched off at the
            // first random failure and checks nothing afterwards.
            wait: { _ in }
        )
    }

    /// `nonisolated`, because this setup is also needed in the closures for the
    /// guide fetch — and those run outside the main thread.
    private nonisolated static func programs(
        _ title: String,
        from start: Date,
        minutes: Double,
        channelID: String = "1"
    ) -> Programme {
        Programme(
            id: title,
            channelID: channelID,
            title: title,
            start: start,
            end: start.addingTimeInterval(minutes * 60)
        )
    }

    // MARK: - Outline

    @Test("The groups follow the provider's order, not the alphabet")
    func groupOrderFollowsProvider() async {
        // Providers order on purpose: domestic before foreign, general-interest channels before specialty ones.
        // Sorted alphabetically, "TR Genel" would come before "DE Vollprogramme", and anyone
        // looking for their German channels would first page through the Turkish ones. That is exactly
        // why ``LiveLibrary/groups(from:)`` keeps the order of discovery — this
        // test pins down that the Live area does not sort it away again.
        let model = Self.model()
        await model.load()

        #expect(model.groupNames == ["DE Vollprogramme", "TR Genel"])
    }

    @Test("Favorites sit above all groups")
    func favoritesComeFirst() async {
        // With 5389 channels, favorites are the real way into the list.
        // If they stood behind the 79 groups, the point of a favorite would be gone.
        var stock = Self.stock()
        stock[3].isFavorite = true

        let model = Self.model(channels: stock)
        await model.load()

        #expect(model.sections.first?.id == LiveModel.favoritesSectionID)
        #expect(model.sections.first?.channels.map(\.id) == ["4"])
        // And the group keeps it anyway: whoever looks in "TR Genel" should find the
        // channel where the provider filed it.
        #expect(model.sections.last?.channels.map(\.id) == ["4"])
    }

    @Test("A group heading is not a channel and is not in the list")
    func sectionMarkersAreNoChannels() async {
        // 113 of 5389 entries are headings of the form "##### SOLA HEVC #####".
        // They have an ID and address like any channel and deliver nothing: whoever
        // selects one sees a black picture without explanation — and looks for the fault in
        // themselves or in the app.
        let model = Self.model()
        await model.load()

        let names = model.sections.flatMap(\.channels).map(\.name)
        #expect(!names.contains { $0.contains("#") })
        #expect(model.sections.first(where: { $0.id == "DE Vollprogramme" })?.channels.count == 2)
    }

    // MARK: - Filter

    @Test("Adult channels stay away without the switch and appear with it")
    func adultChannelsFollowThePreference() async {
        // The direction of the surprise: someone paging through 79 groups with the family
        // should not stumble into one. Conversely the mistake cannot be
        // undone. 294 of 5389 channels carry the marking.
        let model = Self.model()
        await model.load()

        #expect(!model.groupNames.contains("For Adults"))

        model.apply(LivePreferences(showsAdultChannels: true))

        #expect(model.groupNames.contains("For Adults"))
    }

    @Test("A hidden group also disappears from the search")
    func hiddenGroupIsAlsoHiddenFromSearch() async {
        // The reason list and search must use the same filter: a
        // channel that shows up in search but not in the list looks like a
        // bug — and anyone who hid a group has hidden it.
        let model = Self.model(
            preferences: LivePreferences(hiddenGroups: ["TR Genel"])
        )
        await model.load()

        #expect(!model.groupNames.contains("TR Genel"))

        model.search("telve")

        #expect(model.hits.isEmpty)
        #expect(model.hitCount == 0)
    }

    @Test("A channel drops out of the results as soon as its group is hidden")
    func hidingAGroupUpdatesRunningSearch() async {
        // The setting is reachable elsewhere while search is open.
        // If the hit stayed, a hidden channel could still be
        // selected — the filter would be a display matter and not a decision.
        let model = Self.model()
        await model.load()
        model.search("telve")
        #expect(model.hits.count == 1)

        model.apply(LivePreferences(hiddenGroups: ["TR Genel"]))

        #expect(model.hits.isEmpty)
    }

    // MARK: - Search

    @Test("The search goes by the key and not by the displayed name")
    func searchUsesTheKey() async {
        // Both are proven on the catalog and both break search on a
        // remote: 2176 names carry superscript characters — `ᴴᴰ` is not
        // `HD` and cannot be found on any keyboard. And 1313 begin with a prefix
        // like `DE|`; if it stayed, a search for "DE" would find a quarter of the
        // catalog.
        let model = Self.model()
        await model.load()

        model.search("entertainment hd")
        #expect(model.hits.map(\.id) == ["3"], "the folded `ᴴᴰ` must be findable")

        model.search("DE")
        #expect(model.hits.isEmpty, "the provider's prefix is not a search hit")
    }

    @Test("A single letter triggers no search")
    func singleLetterIsNoSearch() async {
        // With 5389 channels a single letter matches almost everything. The list would be replaced
        // by an unusable one at the first keypress, and the way back
        // would not be apparent to the user.
        let model = Self.model()
        await model.load()

        model.select("DE Vollprogramme")
        model.search("t")

        #expect(!model.isSearching)
        #expect(model.shownChannels.count == 2, "the chosen group is still there")
    }

    // MARK: - Outline as on the phone (B9)

    /// **Without a choice, "All" is shown**, with "Recently watched" and the favorites on top — and at the
    /// end the channels without a guide (decision 27, B9, 2026-09-26). Until then
    /// the favorites group came first, and there was an outline only on the phone.
    @Test("\"All\" carries Recently Watched, favorites, with and without programme")
    func allStructured() async throws {
        var catalog = Self.stock()
        catalog[3] = Self.channel(
            "4", "TR: TELVE 1", group: "TR Genel", epgID: "telve1.tr", isFavorite: true)
        let channels = catalog
        let model = LiveModel(
            stock: { LiveModel.Stock(channels: channels) },
            wait: { _ in },
            recent: { [channels[0].channelName] })
        await model.load()
        await model.downloadsRun?.value

        #expect(model.selectedSectionID == LiveModel.overviewSectionID)
        try #require(
            model.segments.map(\.kind) == [.recent, .favorites, .withGuide, .withoutGuide])
        #expect(model.segments[0].entries.map(\.id) == ["1"])
        #expect(model.segments[1].entries.map(\.id) == ["4"])
        #expect(
            model.segments[3].entries.map(\.id) == ["3"], "without programme identifier: without programme")
        #expect(model.shownChannels.map(\.id) == ["1", "4", "3"], "without the abbreviations")
        #expect(model.groupRows.first?.id == LiveModel.overviewSectionID)
        #expect(!model.groupNames.contains(""))

        model.select(LiveModel.favoritesSectionID)
        #expect(model.segments.map(\.kind) == [.withGuide], "shelves only via \"All\"")
        model.search("telve")
        #expect(model.shownChannels.map(\.id) == ["4"])
    }

    // MARK: - Programme

    @Test("A channel without a programme yields no second row")
    func channelWithoutProgrammeHasNoSecondLine() async {
        // Of 5389 channels, 610 find a guide entry — for nine of ten
        // rows there is nothing to report. An empty placeholder or a spinner
        // that never finishes would be the normal case and the list restless.
        let model = Self.model()
        await model.load()

        let withoutEPG = Self.channel("3", "DE| WELLE ENTERTAINMENT ᴴᴰ")
        model.focus(withoutEPG)
        await model.settle(for: withoutEPG)

        #expect(model.runningProgramme(for: withoutEPG, at: Date()) == nil)

        let row = ChannelRow(
            channel: withoutEPG,
            programs: model.runningProgramme(for: withoutEPG, at: Date()),
            now: Date(),
            isFocused: false
        )
        #expect(row.programmeLine == nil, "without a programme the row does not arise at all")
    }

    @Test("Without a programme identifier no request goes out")
    func noEPGIDMeansNoRequest() async {
        // Of 5389 channels, 980 carry a guide ID. For the remaining 4409
        // the fetch would be a request whose answer is certainly empty — and
        // the provider allows exactly one connection. Whoever asks here blocks
        // playback.
        let asked = Counter()
        let model = Self.model(guide: { channel in
            asked.add(channel.id)
            return []
        })
        await model.load()

        let withoutEPG = Self.channel("3", "DE| WELLE ENTERTAINMENT ᴴᴰ")
        model.focus(withoutEPG)
        await model.settle(for: withoutEPG)

        #expect(asked.values.isEmpty)
        #expect(model.guide(for: withoutEPG) == .none, "not queried, but reported")
    }

    @Test("When paging through, only the channel the focus stays on is queried")
    func onlyTheLastFocusIsAsked() async {
        // That is the case this is about: someone driving through 5389 channels with the remote
        // touches twenty rows in two seconds. If every focus change
        // asked again, a flood of fetches would result over a line that
        // allows one connection — and the answer would land on a different row.
        // Same rule as in ``DetailColumn``.
        let asked = Counter()
        let model = Self.model(guide: { channel in
            asked.add(channel.id)
            return [Self.programs("Tagesfunke", from: Date(), minutes: 15, channelID: channel.id)]
        })
        await model.load()

        let first = Self.channel("1", "Das Nordlicht", epgID: "ahorn.de")
        let second = Self.channel("4", "TELVE 1", epgID: "telve1.tr")

        model.focus(first)
        model.focus(second)
        await model.settle(for: second)

        #expect(asked.values == ["4"], "the skipped channel is not queried")
        #expect(model.guide(for: first) == .pending)
    }

    @Test("A second dwell on the same channel does not query again")
    func askedOnlyOnce() async {
        // An empty result also counts as an answer. Without this rule every
        // visit to the same row would ask again for a guide that does not exist —
        // so constantly when paging up and down in a group.
        let asked = Counter()
        let model = Self.model(guide: { channel in
            asked.add(channel.id)
            return []
        })
        await model.load()

        let channel = Self.channel("1", "Das Nordlicht", epgID: "ahorn.de")
        model.focus(channel)
        await model.settle(for: channel)
        model.focus(nil)
        model.focus(channel)
        await model.settle(for: channel)

        #expect(asked.values == ["1"])
    }

    @Test("The remaining time is rounded up and disappears when the programme ends")
    func remainingMinutesRoundUp() {
        // Rounded down, the last minute would read "0 min left" — a number that
        // looks as if the show were over while it is still running. And after the
        // end no number may remain: a remaining time on an expired
        // show is worse than none, because people believe it.
        let now = Date(timeIntervalSince1970: 1_785_248_700)
        let running = Self.programs("Tagesfunke", from: now.addingTimeInterval(-60), minutes: 15)

        #expect(LiveModel.remainingMinutes(of: running, at: now) == 14)

        // Thirty seconds before the end: rounded up one minute, not zero.
        let almostOver = Self.programs("Ende", from: now.addingTimeInterval(-30), minutes: 1)
        #expect(LiveModel.remainingMinutes(of: almostOver, at: now) == 1)

        let over = Self.programs("Vorbei", from: now.addingTimeInterval(-3600), minutes: 30)
        #expect(LiveModel.remainingMinutes(of: over, at: now) == nil)

        let later = Self.programs("Später", from: now.addingTimeInterval(600), minutes: 30)
        #expect(LiveModel.remainingMinutes(of: later, at: now) == nil)
    }

    // MARK: - Favorites

    @Test("A newly set favorite is on top at once — and only the chosen version")
    func favoriteMovesUpImmediately() async {
        // Two things at once, and both otherwise only show up later: the view
        // must show the change without a new fetch — fetching 5389 channels a second time
        // to set a star would mean a minute of waiting over the tunnel.
        // And since 2026-08-15 the ID marks **exactly the selected
        // version** (on-device finding: "KopruHaber HD" pulled in UHD, FHD and HEVC) —
        // so the 576p version is explicitly left without a star.
        let written = Counter()
        let stock = [
            Self.channel("1", "Das Nordlicht (1080p)", group: "DE"),
            Self.channel("2", "Das Nordlicht (576p)", group: "DE"),
            Self.channel("3", "ZINNE", group: "DE"),
        ]
        let model = Self.model(
            channels: stock,
            setFavorite: { channel, isFavorite in
                written.add("\(channel.id):\(isFavorite)")
            })
        await model.load()

        model.toggleFavorite(stock[0])

        #expect(written.values == ["1:true"], "stored once, not per delivery")
        #expect(model.sections.first?.id == LiveModel.favoritesSectionID)
        #expect(model.sections.first?.channels.map(\.id) == ["1"])
    }

    /// **The same favorite under a different spelling follows** — compared via the
    /// store's key (``Flows/LiveCatalog/setFavorite(_:for:in:)``, AP58 R5),
    /// the same rule as on the phone.
    @Test("A favorite also matches the other spelling of the same channel")
    func favoriteFollowsSpelling() async {
        let stock = [
            Self.channel("1", "Das Nordlicht HD", group: "DE"),
            Self.channel("2", "DAS NORDLICHT | HD", group: "DE"),
            Self.channel("3", "Das Nordlicht UHD", group: "DE"),
        ]
        let model = Self.model(channels: stock)
        await model.load()

        model.toggleFavorite(stock[0])

        #expect(model.sections.first?.id == LiveModel.favoritesSectionID)
        #expect(model.sections.first?.channels.map(\.id) == ["1", "2"])
    }

    // MARK: - Playback

    @Test("A channel's target does not seek and reports no progress")
    func liveTargetHasNoSeekingAndNoProgress() async {
        // A channel has no end, no middle and nothing to remember. If it appeared as
        // "40% watched" on Home, that would be a bug you only notice
        // once it is there — and then on every device.
        let model = Self.model()
        await model.load()

        let channel = Self.channel("1", "DE| DAS NORDLICHT ᴴᴰ")
        let target = model.target(for: channel)

        #expect(target.kind == .live)
        #expect(target.isSeekable == false)
        #expect(target.tracksProgress == false)
        #expect(target.itemID == nil)
        #expect(target.title == "DE| DAS NORDLICHT HD", "the folded name is on screen")
    }

    @Test("The bandwidth limit does not apply to a channel")
    func bandwidthLimitDoesNotApplyToLive() async {
        // With Jellyfin the server transcodes down when the line is not enough.
        // An IPTV provider cannot do that — it delivers the channel at a measured
        // 17 Mbit/s, or not at all. Passing a limit would order a conversion
        // that nobody carries out: the decision would show a limit that does not
        // apply, and when hunting for stutter it would point in the wrong direction.
        let channel = Self.channel("1", "Das Nordlicht")

        let decision = LiveModel.decision(for: channel)

        #expect(decision.maxBitrate == nil)
        // **Apple's engine does not open MPEG-TS — raw.** Since 2026-08-10 the app
        // repackages the channel itself and gives Apple's engine a
        // playlist it knows. This changes nothing about the conversion: it still
        // takes place nowhere.
        #expect(decision.delivery == .remuxInApp)
    }

    @Test("A channel as HLS goes out unchanged")
    func hlsIsDeliveredUntouched() async {
        // Not every provider delivers MPEG-TS. Apple's engine can do HLS itself,
        // and then every detour is one too many: it costs hardware
        // decoding, AirPlay and Picture in Picture.
        //
        // **What is checked is the delivery path** (AP8, added 2026-09-02); the old
        // assertion "goes to the system player" had been true since the VLC removal,
        // no matter what the channel delivers.
        let channel = Self.channel("1", "Das Nordlicht", suffix: "m3u8")

        #expect(LiveModel.decision(for: channel).delivery == .directPlay)
    }

    // MARK: - Channel address choice, both halves on the TV

    /// **The address half** (AP58 final step): a channel that has gone blind once
    /// goes straight out as a raw stream — on the phone `ChannelAddressPhoneTests` checks the same.
    @Test("A remembered channel goes straight out as a raw stream")
    func rememberedChannelGoesRaw() {
        let channel = Self.channel("7", "Das Nordlicht", suffix: "m3u8")
        let store = InMemoryStore()
        #expect(LiveModel.streamURL(for: channel, store: store) == channel.streamURL)

        var watchlist = RawStreamMemory.load(from: store)
        watchlist.remember(channel.streamURL)
        watchlist.save(to: store)
        #expect(LiveModel.streamURL(for: channel, store: store).pathExtension == "ts")
    }

    /// **The engine half:** The direct renderer gets the raw stream; without HEVC there is
    /// no repackager — the same rule the phone runs with a fixed direct renderer.
    @Test("Engine and HEVC gate decide the path of a raw stream")
    func engineAndHEVC() {
        let raw = URL(string: "http://anbieter.example/live/user/pass/1.ts")!
        #expect(
            LiveModel.decision(forURL: raw, canDecodeHEVC: true, motor: .renderer).delivery == .renderInApp)
        #expect(LiveModel.decision(forURL: raw, canDecodeHEVC: true, motor: .hls).delivery == .remuxInApp)
        #expect(!LiveModel.decision(forURL: raw, canDecodeHEVC: false, motor: .hls).runsOverRepacker)
    }

    // MARK: - Screen space

    /// What is left next to the collapsed sidebar.
    static var available: CGFloat { LiveView.screenWidth - AppSidebar.collapsedWidth }

    /// What the two-column part needs at minimum in width.
    static var neededWidth: CGFloat {
        2 * MetricsBoard.tv.margin + LiveView.listWidth + LiveView.columnGap
            + NowPlayingPanel.minimumWidth
    }

    @Test("Channel list and board fit next to the sidebar")
    func listAndPanelFit() {
        // SwiftUI does not warn about this: content that is too wide is centered and overflows
        // on **both** sides. All you would see is the list sliding under
        // the sidebar and the guide missing on the right — that looks like
        // an edge bug and is a space bug.
        #expect(
            Self.neededWidth <= Self.available,
            """
            Zu breit: \(Int(Self.neededWidth)) Punkte gebraucht, \
            \(Int(Self.available)) vorhanden. Entweder die Senderliste schmaler oder
            die Tafel.
            """
        )
    }

    @Test("The expanded sidebar leaves the board standing too")
    func expandedSidebarLeavesThePanel() {
        // The bar opens as soon as focus enters it, and pushes the content
        // aside. If too little were left for the board, the layout would fall apart
        // every time one reaches for the bar — exactly at the moment when
        // one selects a group.
        let room = LiveView.screenWidth - AppSidebar.expandedWidth
        let slack = room - Self.neededWidth

        #expect(slack >= 40, "only \(Int(slack)) points to spare — the layout breaks on expanding")
    }

    @Test("The enlarged focused row keeps its distance from the board")
    func focusedRowStaysInTheGap() {
        // The row grows on focus and sticks out on both sides. If the gap
        // to the board is smaller than this overhang, the row slides over the
        // guide — and because it is focused, it looks as if that is how it should be.
        let overhang = (LiveView.listWidth * Tokens.Focus.buttonScale - LiveView.listWidth) / 2

        #expect(overhang <= LiveView.columnGap)
    }

    @Test("The row adds up across its width")
    func rowWidthAddsUp() {
        // Every component has a fixed place, and the sum must be the width of the
        // list. If the calculation does not add up, the channel name is truncated
        // or the "LIVE" badge is pushed out of the row — both look like
        // a data bug and are a layout bug.
        let sum =
            2 * ChannelRow.inset + ChannelRow.logoSize.width + ChannelRow.gap
            + ChannelRow.textWidth + ChannelRow.gap + ChannelRow.badgeWidth

        #expect(sum == LiveView.listWidth)
        // And enough must be left for a channel name. At font size 25,
        // 300 points are about twenty characters — "SOLA CINEMA PREMIEREN" fits, more gets
        // truncated, and that is the limit of the tolerable.
        #expect(ChannelRow.textWidth >= 300)
    }

    @Test("The programme list in the board does not run off screen")
    func guideRowsFitBelowTheTile() {
        // The fetch returns 24 entries. Writing all of them out would produce a list
        // that runs off the bottom — and because the rows are text and not buttons,
        // none of them takes focus, so there is no way to scroll to them.
        // What is not reachable must not be longer than the picture.
        let rows =
            CGFloat(NowPlayingPanel.maximumGuideRows) * NowPlayingPanel.guideRowHeight
            + CGFloat(NowPlayingPanel.maximumGuideRows - 1) * NowPlayingPanel.guideRowSpacing

        #expect(Self.panelUsedHeight + rows <= LiveView.screenHeight)
        // One more row demonstrably did not fit — without this half the
        // number looks arbitrary, and the next person sets it higher.
        #expect(
            Self.panelUsedHeight + rows + NowPlayingPanel.guideRowSpacing
                + NowPlayingPanel.guideRowHeight > LiveView.screenHeight
        )
        #expect(NowPlayingPanel.maximumGuideRows >= 3, "below three rows the programme says nothing")
    }

    /// What lies in the board above the guide list.
    static var panelUsedHeight: CGFloat {
        LiveView.contentTop + NowPlayingPanel.tileRowHeight + NowPlayingPanel.actionsHeight
            + NowPlayingPanel.hintHeight + NowPlayingPanel.guideTop + TVMetrics.topMargin
    }

    @Test("The top row of the board is determined by the header column, not by the image board")
    func headingDecidesTheTileRowHeight() {
        // The bug this test prevents had been built in: the calculation used
        // the height of the picture board (236). But a two-line channel name with a running
        // show makes the row 282 points high — and because the board sits in the same
        // `VStack` as the title and group tabs, SwiftUI centers the too-tall
        // stack: the title moves out past the top edge of the screen, and at the bottom
        // the last guide row is missing. Two bugs from one number, both without
        // a warning.
        //
        // Two-line names are the rule here and not the exception: of
        // 5389 recorded names, 4521 carry a provider prefix and become
        // long as a result.
        #expect(
            NowPlayingPanel.headingHeight > NowPlayingPanel.tileSize.height,
            "otherwise the image board may be counted on — then change this test"
        )
        #expect(NowPlayingPanel.tileRowHeight == NowPlayingPanel.headingHeight)
    }

    @Test("The group list reaches the settings without displacing them")
    func sidebarGroupListFillsTheGap() {
        // A `VStack` that becomes taller than the screen is centered by SwiftUI:
        // the topmost and bottommost entries then disappear — without
        // a warning and without any way to scroll. That is why the list gets **exactly** the
        // space that is left next to everything else, and not one point more.
        // **The number is no longer here but in one place** —
        // ``AppSidebar/mainRows``. Before, it stood twice: once there
        // as `6` and once here, and both were two too low. Sports and
        // portals were added later and were not added to either of the
        // two; this test case, which was supposed to warn of exactly that,
        // confirmed the same wrong number.
        //
        // If a main entry is added, the test case still fails — it
        // compares the calculation with the screen. But it no longer forces anyone
        // to change a number in two places.
        let fixed =
            2 * AppSidebar.verticalPadding + AppSidebar.brandHeight
            + CGFloat(AppSidebar.mainRows) * AppSidebar.rowHeight
            + CGFloat(AppSidebar.mainRows + 2) * AppSidebar.rowSpacing

        #expect(fixed + AppSidebar.groupListHeight == AppSidebar.screenHeight)

        // And the space must also be used. A fixed number stood here that was
        // 139 points too low: a third of the bar stayed empty while one had to
        // page at the top. A number that is too small goes unnoticed without this check —
        // it does not look wrong, just tight.
        let perRow = AppSidebar.groupRowHeight + AppSidebar.rowSpacing
        #expect(
            AppSidebar.groupListHeight + perRow > AppSidebar.screenHeight - fixed,
            "there would still be room for a group — the height is too low"
        )
        // **`>= 8` stood here, and the number could no longer be held since sports and
        // portals** — the calculation gives four. It stayed green anyway,
        // because `fixed` above used the same outdated six: the check
        // measured the calculation against itself instead of against the screen.
        //
        // Four is little, and that is an honest finding and not a promise: the
        // bar now carries nine main entries, and the space is used
        // up. Whoever wants to see more groups has to change something about the bar —
        // not about this number.
        #expect(
            AppSidebar.visibleGroupCount >= 4,
            "below four visible groups expanding is no longer worth it"
        )
    }

    @Test("A flat list would not be usable — hence the outline")
    func aFlatListWouldBeUnusable() {
        // Pins down the rationale of the whole area as a calculation. Eight rows fit in one
        // picture height; 5389 channels would be over 600 picture heights with
        // the remote. Without this number the effort for groups,
        // favorites and search looks like decoration.
        #expect(LiveView.rowsPerScreen >= 7, "otherwise the row is too tall")
        #expect(LiveView.rowsPerScreen <= 10, "otherwise the row is not readable from three metres")
        #expect(5389 / LiveView.rowsPerScreen > 500)
    }
}

// MARK: - Tooling

extension LiveModel {

    /// Waits until the triggered fetch is through.
    ///
    /// Needed because the fetch has two suspension points — the dwell time and the
    /// query itself. A single ``Task/yield()`` is not enough for that, and a
    /// wait in the test suite would be a race that eventually fails at random.
    func settle(for channel: Channel) async {
        for _ in 0..<20 {
            await Task.yield()
            if guide(for: channel) != .pending { return }
        }
    }
}

/// Records what was asked for.
///
/// A class and not an `inout` counter: the closures are called across
/// actor boundaries, and a captured value would be a copy.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func add(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(value)
    }
}

/// Whether the guide arrives for a group when one selects it.
///
/// **The finding this pins down** (2026-08-08): "On first opening the
/// content is not there yet; go into a movie and back out once, then everything is
/// there." The stock were queried only when the catalog was rebuilt, not when
/// switching groups. Whoever opens the app lands in their last group via the remembered
/// name — so exactly on this path. The list was
/// there, the shows were missing; only the detour through playback rebuilt the
/// catalog, and then everything was there.
@Suite("Programme when switching group")
@MainActor
struct LiveGroupSwitchTests {

    private static func channel(_ id: String, group: String, epgID: String) -> Channel {
        Channel(
            id: id,
            name: "Sender " + id,
            streamURL: URL(string: "http://host/live/u/p/\(id).m3u8")!,
            playlistID: "liste",
            group: group,
            epgID: epgID
        )
    }

    /// Whether a show is actually there.
    ///
    /// **And not `!= .none`, which this test suite hung on for years** (AP50, 2026-09-23).
    /// ``LiveModel/guide(for:)`` has **three** outcomes: `.pending` as long as nothing is known
    /// about the channel, `.none` for "asked, nothing there", and `.listing` with the
    /// shows. `!= .none` is therefore also true when **nothing has arrived at all** —
    /// the expectation claimed "the channel shows its show" and checked "it is not
    /// known that it has none".
    private func showsBroadcast(_ model: LiveModel, _ channels: Channel) -> Bool {
        if case .listing = model.guide(for: channels) { return true }
        return false
    }

    /// Wait for the grab into the stock — **and do not look at a clock.**
    ///
    /// **This test suite took four attempts, and three of them were deadlines.** Here
    /// stood in turn fifty milliseconds, two seconds and ten — each of them
    /// measured how busy the machine is, and not what the test suite
    /// claims. Alone it ran through in 4.3 seconds; in the full run with 661
    /// checks it was green once and red the next time.
    ///
    /// **The cause was not time but a missing handle.**
    /// ``LiveModel/fillGuidesFromStore()`` started its `Task { }` without a handle; from
    /// outside only polling remained. Now the model holds the task (``LiveModel/downloadsRun``),
    /// and here it is awaited. That is deterministic: if the stock never come, the
    /// test suite hangs and reports it as a timeout of the runner — more honest than
    /// a deadline that decides at random under load.
    private func waitForStock(_ model: LiveModel) async {
        await model.downloadsRun?.value
    }

    /// `nonisolated`, because the closure for the stock runs outside the
    /// main thread — just like the guide fetch above.
    private nonisolated static func programs(_ channelID: String) -> Programme {
        Programme(
            id: "p-" + channelID,
            channelID: channelID,
            title: "Sendung " + channelID,
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 3600)
        )
    }

    @Test("The chosen group gets its programme from the cache")
    func switchingGroupsFillsTheGuide() async throws {
        let stock = [
            Self.channel("1", group: "Erste", epgID: "e1"),
            Self.channel("2", group: "Zweite", epgID: "e2"),
            Self.channel("3", group: "Zweite", epgID: "e3"),
        ]

        let model = LiveModel(
            preferences: LivePreferences(),
            stock: { LiveModel.Stock(channels: stock) },
            // Explicitly empty: what is checked is the path via the **stock**, not
            // the single fetch on focus. If that returned something here, it would not be possible
            // to tell which of the two paths filled the row.
            guide: { _ in [] },
            storedGuides: { channels in
                var result: [String: [Programme]] = [:]
                for channel in channels { result[channel.id] = [Self.programs(channel.id)] }
                return result
            },
            setFavorite: { _, _ in },
            wait: { _ in }
        )

        await model.load()
        // The stock are queried in a task of their own — its result arrives on the
        // next pass of the main thread. When that is depends on the load.
        await waitForStock(model)

        // Now select the second group — the path the remembered
        // group also takes at startup.
        let second = try #require(model.sections.first { $0.name == "Zweite" })
        model.select(second.id)
        await waitForStock(model)

        #expect(
            showsBroadcast(model, stock[1]),
            "the first channel of the new group shows its programme"
        )
        #expect(
            showsBroadcast(model, stock[2]),
            "and the second too — not only the one the focus is on"
        )
    }
}

/// Back from the player (F-040, 2026-09-04): a second load must neither
/// show the spinner nor throw focus back to the start.
@MainActor
struct LiveReloadTests {

    private static func channel(_ id: String, group: String = "Nachrichten") -> Channel {
        Channel(
            id: id, name: "Sender \(id)",
            streamURL: URL(string: "http://example.com/\(id).ts")!, playlistID: "p",
            group: group)
    }

    @Test("A second load leaves the catalog and keeps the focus")
    func reloadKeepsStateAndFocus() async {
        let channels = ["1", "2", "3"].map { Self.channel($0) }
        let model = LiveModel(
            preferences: LivePreferences(),
            stock: { LiveModel.Stock(channels: channels) },
            guide: { _ in [] },
            setFavorite: { _, _ in },
            wait: { _ in }
        )
        await model.load()
        #expect(model.state == .ready)
        model.focus(channels[2])

        var seenLoading = false
        let watcher = model.$state.sink { if $0 == .loading { seenLoading = true } }
        defer { watcher.cancel() }
        await model.load()

        #expect(!seenLoading)
        #expect(model.state == .ready)
        #expect(model.focused?.id == "3")
    }

    @Test("If the focused channel vanishes, the focus jumps to the start")
    func reloadWithoutTheFocusedChannel() async {
        let first = ["1", "2", "3"].map { Self.channel($0) }
        let then = ["1", "2"].map { Self.channel($0) }
        let round = TallyCounter()
        let model = LiveModel(
            preferences: LivePreferences(),
            stock: {
                round.next() == 1 ? LiveModel.Stock(channels: first) : LiveModel.Stock(channels: then)
            },
            guide: { _ in [] },
            setFavorite: { _, _ in },
            wait: { _ in }
        )
        await model.load()
        model.focus(first[2])
        await model.load()
        #expect(model.focused?.id == "1")
    }

    private final class TallyCounter: @unchecked Sendable {
        private var state = 0
        private let lock = NSLock()
        func next() -> Int {
            lock.withLock {
                state += 1; return state
            }
        }
    }
}

/// The cursor on the most recently watched channel (F-008, 2026-09-04).
@MainActor
struct LiveRememberedFocusTests {

    private static func channel(_ id: String, group: String, favorite: Bool = false) -> Channel {
        Channel(
            id: id, name: "Sender \(id)",
            streamURL: URL(string: "http://example.com/\(id).ts")!, playlistID: "p",
            group: group, isFavorite: favorite)
    }

    private static func model(_ channels: [Channel]) -> LiveModel {
        LiveModel(
            preferences: LivePreferences(),
            stock: { LiveModel.Stock(channels: channels) },
            guide: { _ in [] },
            setFavorite: { _, _ in },
            wait: { _ in }
        )
    }

    @Test("The remembered channel gets the focus, even in another group")
    func focusesRememberedAcrossGroups() async {
        let model = Self.model([
            Self.channel("1", group: "TR"), Self.channel("2", group: "TR"),
            Self.channel("3", group: "DE"), Self.channel("4", group: "DE"),
        ])
        await model.load()
        #expect(model.focused?.id == "1")
        #expect(model.focusRemembered("4"))
        #expect(model.focused?.id == "4")
        #expect(model.shownChannels.contains { $0.id == "4" })
        #expect(!model.focusRemembered("99"))
        #expect(!model.focusRemembered(nil))
        #expect(model.focused?.id == "4")
    }
}
