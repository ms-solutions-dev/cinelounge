import Core
import DesignSystemPhone
import Flows
import Foundation
import NetworkStatus
import ParentalControls
import PlaylistKit
import SwiftUI

/// Tab 3: Channels and Sports in one tab.
///
/// On the TV the Live area has over 300 focusable elements — 23 sports plus
/// four buttons per channel group across 79 groups. In this form it is
/// impossible at 393 points; splitting into two modes with a switch is the answer
/// to that.
///
/// **Sports variant 1** (decision 27, C15, 2026-09-26): the content is the same everywhere —
/// schedule, filter, watchlist —, only the entry follows the device. On the TV, Sports is
/// a separate entry of the sidebar; here the "Channels | Sports" switch stands **at the top**
/// of the Live tab, because the iPhone's tab bar shows only five slots. Until
/// 2026-09-26 it stood at the bottom above the tab bar.
public struct LiveView: View {

    @Environment(\.horizontalSizeClass) private var widthClass

    @State private var model: LiveModel
    /// The schedule — **only if the page exists** (Live check, finding 4, 2026-09-27).
    ///
    /// Until then it was built unconditionally, even for a child, and read the watchlist in the process.
    /// On the first read after the update, the adoption of the old lists went to the profile
    /// that read first — if that was a child with a channel list, the parents'
    /// bookmarks ended up in its slot and were deleted at the old places.
    @State private var sport: SportModel?
    /// Which page was open last — **beyond the program run.**
    ///
    /// The same rule as for the library catalog: "If I was at Sports, I land
    /// at Sports again." Whoever uses the schedule uses it regularly; making them
    /// search for it anew on every launch would be a convenience paid for once a day.
    ///
    /// `CINELOUNGE_LIVE=sport` overrides the memory — a check hook, not a feature:
    /// the simulator accepts no tap commands from outside, and the Sports page would otherwise
    /// not be viewable.
    @AppStorage("live.lastSide") private var sportRemembered = false
    @State private var isSportSelected = false
    @State private var isGroupSheetOpen = false
    /// Which channel is opened — **the bundle and not its identifier.**
    ///
    /// **Why this is a sheet and not a view of the wrapper.** The wrapper drives its
    /// views via ``ViewID`` and passes a **string** through.
    /// Recovering a ``ChannelBundle`` from a channel identifier would mean loading the list
    /// of all 7,746 channels a second time — on an account with **one**
    /// permitted connection exactly what ``ChannelListingSource`` avoids elsewhere.
    /// The sheet keeps what the list already has in hand.
    @State private var expanded: ChannelBundle?

    /// Whether the program grid stands instead of the list — **only on the iPad** (B10).
    @State private var showsGrid = false
    @State private var raster: GuideGridModel

    /// The clock everything hangs on.
    ///
    /// **One for the whole list and not one per row.** With `Date()` in the body of each
    /// row, each computed with a second of its own — two broadcasts of equal length showed
    /// different remaining times, and nobody would find the reason. It advances by
    /// the minute, because the remaining time is in minutes: more often would be work without visible
    /// effect.
    ///
    /// **The tick stands in a `TimelineView` around the list and no longer in the body of
    /// this view.** Before, `now` hung as `@State` at the root: every minute
    /// **everything** was re-evaluated — header, large title, location line, segment and the
    /// whole schedule — to change one remaining time in twelve visible rows. The
    /// `TimelineView` draws this circle around exactly what the clock really reads.
    @State private var now = Date()

    /// Where the device currently is — see ``LocationMonitor``.
    ///
    /// **Default `unknown` and not `home`** (AP6): until 2026-09-10. `.home` stood
    /// hard-coded in the body here. Whoever was out and about read information about their network
    /// that came from a line of code. With an unknown location, no location line appears.
    var location: LocationStatement.Location = .unknown

    /// The source the list also comes from — **the same for the channel sheet.** Until
    /// AP52 the sheet built one of its own; since a child gets a filtered one, that
    /// would have been a second, unfiltered one.
    private let source: (any ChannelListingSource)?

    /// Whether the "Sports" page exists — **not for a child** (AP52): the schedule
    /// computes over all channels, and for sports there is no allow list.
    private let withSport: Bool

    private let account: String
    private let onAccountTap: () -> Void
    /// The way to the favorites — **`nil` if they stand at the bottom of the bar.**
    ///
    /// With a full setup the bar is full, and the favorites move to the
    /// top (``CatalogState/favoritesAtBottom``). Without this heart they would then be reachable from
    /// **nowhere** — the tab is missing precisely for that reason.
    private let onFavoritesTap: (() -> Void)?
    private let playChannel: (Channel) -> Void
    /// Play a past broadcast as a recording (A2).
    private let playRecording: (Channel, PlaybackJob.CatchUpRequest) -> Void

    public init(
        source: (any ChannelListingSource)?,
        withSport: Bool,
        account: String = "?",
        onAccountTap: @escaping () -> Void = {},
        onFavoritesTap: (() -> Void)? = nil,
        matches: @escaping (Channel) -> Void = { _ in },
        playRecording: @escaping (Channel, PlaybackJob.CatchUpRequest) -> Void = { _, _ in },
        location: LocationStatement.Location = .unknown
    ) {
        self.location = location
        self.source = source
        self.withSport = withSport
        // **The saved settings, re-read on every load.** See
        // ``LiveModel/init(source:preferences:loadPreferences:history:)``: until 2026-09-06
        // the factory setting stood here, and hidden groups were back after
        // switching tabs.
        // The channel block filters the source itself (`LiveLibrary`).
        let liveModel = LiveModel(
            source: source, loadPreferences: { LivePreferences.load(from: ProfileStore.playback) })
        _model = State(initialValue: liveModel)
        // **The schedule names EPG IDs, the screen needs channel names.**
        // The translation lives with the channel part, because that is where the channel list is; repeating it
        // here would mean keeping the same board twice.
        _sport = State(
            initialValue: withSport
                ? SportModel(
                    source: source, names: { [weak liveModel] in liveModel?.channelName(forEpg: $0) },
                    loadSelection: { SportFilterSettings.load(from: SecureStore()) })
                : nil)
        self.account = account
        self.onAccountTap = onAccountTap
        self.onFavoritesTap = onFavoritesTap
        self.playChannel = matches
        self.playRecording = playRecording
        _raster = State(
            initialValue: GuideGridModel { channels, from, until in
                await source?.gridProgramme(forItem: channels, from: from, until: until) ?? [:]
            })
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HeaderRow(
                    account: account, onAccountTap: onAccountTap,
                    onFavoritesTap: onFavoritesTap
                )
                .padding(.bottom, 8)

                LargeTitle(title: "tab.live")
                    .padding(.horizontal, MetricsBoard.phone.margin)

                LocationRow(statement: LocationStatement.forItem(.live, location: location))

                if withSport { segment }

                if isSportSelected, let sport {
                    schedule(sport)
                } else {
                    channelList
                }
            }
        }
        .sheet(isPresented: $isGroupSheetOpen) { groupSheet }
        .sheet(item: $expanded) { bundles in
            ChannelDetailView(
                bundles: bundles, source: source,
                matches: { channel in
                    expanded = nil
                    playAndRemember(channel)
                },
                playRecording: { channel, broadcast in
                    expanded = nil
                    playAfter(channel, start: broadcast.start, end: broadcast.end, title: broadcast.title)
                },
                back: { expanded = nil }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
        }
        .onAppear {
            isSportSelected =
                withSport
                && (ProcessInfo.processInfo.environment["CINELOUNGE_LIVE"] == "sport"
                    || sportRemembered)
        }
        .onChange(of: isSportSelected) { _, fresh in if withSport { sportRemembered = fresh } }
        .task {
            await model.load()
            jumpToLastChannel()
            // **`CINELOUNGE_PROGRAMM=fresh` reconciles once on opening.** Not a
            // feature but a check hook: the simulator accepts no tap commands from
            // outside, and a channel row with a running broadcast can otherwise only be
            // seen if the cache is already filled. The same pattern as
            // `CINELOUNGE_SPIELER` and `CINELOUNGE_ZUSTAND`.
            if ProcessInfo.processInfo.environment["CINELOUNGE_PROGRAMM"] == "frisch" {
                await model.fresh()
            }
        }
        .task(id: ScheduleState(expanded: isSportSelected, tag: dayStart)) {
            // **The schedule is loaded when it is opened** — and not when
            // the area is opened. The calculation runs over the program of an entire
            // day; whoever only wants to check which channel is on should not
            // pay for it.
            if isSportSelected { await sport?.load(um: now) }
        }
        .task {
            // **The clock for everything except the channel list.** The schedule hangs on it
            // (it computes time windows) and so does the day change; the channel list has its
            // own `TimelineView` and no longer needs it. Redrawing every minute
            // is thus limited to the schedule — and that stands only when it is
            // opened.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
    }

    /// What the schedule hangs on: **the choice and the read tick.**
    ///
    /// **Hung only on the choice, the plan from earlier would stand after hours.** `now` keeps running
    /// by the minute, but `isSportSelected` no longer changes — whoever opens the schedule
    /// in the evening and leaves the app lying would see yesterday's broadcasts in the morning.
    ///
    /// **And expressly not on `now` itself.** That would reload the plan every minute —
    /// with a provider account with **one** permitted connection, exactly that is the
    /// connection storm that ``LiveModel`` avoids elsewhere.
    private struct ScheduleState: Equatable {
        let expanded: Bool
        let tag: Date
    }

    /// **The full hour in which the read window jumps** — ``Flows/SportsSchedule/readInterval(um:)``.
    /// Until 2026-09-26 it was the broadcast day (five in the morning); since the window rolls
    /// as on the TV (AP58 R5), the hour is the step at which anything changes at all.
    private var dayStart: Date { SportsSchedule.readInterval(um: now) }

    // MARK: - Channels

    @ViewBuilder
    private var channelList: some View {
        switch model.state {
        case .isLoading:
            LoadingState(message: "live.loading").frame(maxHeight: .infinity)
        case .disrupted(let state):
            // The same dead button as on Home — see ``StartView``.
            StateView(state: state, action: { Task { await model.load() } })
        case .empty:
            // **Hidden is not the same as not set up.** One case
            // is settled with a switch, the other requires a setup —
            // see ``PlaybackPhase/emptyLiveHidden``.
            StateView(
                state: .emptyLiveHidden,
                action: { Task { await model.load() } })
        case .settled:
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgramAge(state: model.status, isRefreshing: model.isRefreshing) {
                Task { await model.fresh() }
            }
            .padding(.bottom, 4)

            groupRow

            if showsGrid, widthClass == .regular {
                TimelineView(.periodic(from: .now, by: 60)) { cadence in
                    ProgramGridView(model: raster, now: cadence.date) { channel, cell in
                        playFromGrid(channel, cell, now: cadence.date)
                    }
                }
            } else {
                channelPart
            }
        }
        // **Hung on group and search term, not on the rows** — collecting their identifiers
        // anew on every draw with 7,746 channels would be the work that ``LiveModel``
        // saves elsewhere.
        .onChange(of: model.chosen) { _, _ in showGrid() }
        .onChange(of: model.searchTerm) { _, _ in showGrid() }
        .onChange(of: model.gridRevision) { _, _ in showGrid() }
    }

    private func showGrid() {
        if showsGrid { raster.show(model.rows.map(\.leader)) }
    }

    private var channelPart: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **The search field was ready and never used.** `Channel.searchKey` has been there
            // since the shared package was built: it folds the decorative characters (a search
            // for "HD" otherwise came up empty, because there stands `ᴴᴰ`) and throws away the provider's
            // prefix (otherwise 1,313 channels begin with "DE"). With 7,746 channels
            // it is the fastest way to "a channel whose name I know".
            SearchField(text: $model.searchTerm, placeholder: "live.searchPrompt")
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.bottom, Metrics.targetSpacing)

            if model.rows.isEmpty {
                emptyAfterSearch
            } else {
                // **Only the list hangs on the clock.** See ``now``: before, the whole tab
                // redrew every minute.
                TimelineView(.periodic(from: .now, by: 60)) { cadence in
                    ChannelListScreen(
                        segments: model.segments,
                        program: { model.program(zu: $0) },
                        now: cadence.date,
                        open: playAndRemember,
                        memorize: { channel in Task { await model.setEnabled(favorite: channel) } },
                        showProgram: { expanded = $0 })
                }
            }
        }
    }

    /// Nothing found — **and the difference from "nothing set up".**
    ///
    /// An empty state after a search is not a failure: the catalog is there, it is just that nothing
    /// matches. The way out is clearing the search term and not a setup.
    private var emptyAfterSearch: some View {
        StateBlock(
            form: .info(
                StateInfo(
                    icon: Glyph.Tab.search.outlined,
                    headline: "live.search.none.title", message: "live.search.none.text"))
        )
        .frame(maxHeight: .infinity)
    }

    /// The chosen group as a **title choice** — and no longer as a chip row.
    ///
    /// **The chip row was drawn against a different catalog.** The draft shows
    /// five curated chips; what was built was `ForEach(model.groups)` without an upper limit, and the
    /// provider carries **96** groups — two and a half chips per screen width. Whoever
    /// wanted to reach the last one swiped horizontally thirty-eight times. The same move
    /// as in the library and portals: a title that opens a sheet.
    private var groupRow: some View {
        HStack(spacing: Metrics.targetSpacing) {
            TitleChoice(title: groupTitle) { isGroupSheetOpen = true }
            Spacer(minLength: 0)
            // **The grid only where there is room** (B10): on the iPad, not on the iPhone.
            if widthClass == .regular {
                Button {
                    showsGrid.toggle()
                    if showsGrid {
                        raster.show(model.rows.map(\.leader))
                    } else {
                        raster.stop()
                    }
                } label: {
                    Label {
                        Text(appKey: showsGrid ? "live.rasterBack" : "live.raster")
                    } icon: {
                        Image(systemName: showsGrid ? Glyph.list.name : Glyph.dayPlan.name)
                    }
                }
                .buttonStyle(.bordered)
                .padding(.trailing, MetricsBoard.phone.margin)
            }
        }
        .padding(.bottom, Metrics.targetSpacing)
    }

    /// A tap in the grid — **the TV's rule** (``Flows/CatchUpSelection``).
    private func playFromGrid(_ channel: Channel, _ cell: ProgramGrid.Cell, now: Date) {
        guard
            let archive = model.catchUp(
                leader: channel, start: cell.start, end: cell.end,
                isGap: cell.isGap, now: now)
        else {
            playAndRemember(channel)
            return
        }
        playAfter(archive, start: cell.start, end: cell.end, title: cell.title)
    }

    /// A past broadcast as a recording — **the channel still goes into "Recently
    /// watched"**: whoever catches up has just watched the channel.
    private func playAfter(_ channel: Channel, start: Date, end: Date, title: String) {
        model.note(channel)
        playRecording(channel, PlaybackJob.CatchUpRequest(start: start, end: end, title: title))
    }

    /// "Live" opens the most recently watched channel — **once per session, and only without
    /// an overview** (decision 27, C14, ``Flows/LiveEntry``). The switch for it is under
    /// Settings → Live, as on the TV. Not on the Sports page: whoever was there
    /// wanted the schedule.
    private func jumpToLastChannel() {
        guard !LiveJump.done else { return }
        LiveJump.done = true
        let target = model.lastChannel
        guard !isSportSelected,
            LiveEntry.jumpsDirectly(
                failed: false, jumped: false, isPlaying: false,
                overview: LivePreferences.load(from: ProfileStore.playback).showsBrowseArea,
                remembered: target != nil),
            let target
        else { return }
        playAndRemember(target)
    }

    private var groupTitle: String {
        guard let chosen = model.chosen else {
            let word = AppLanguageSetting.text("common.all")
            return "\(word) \(model.visibleCount.formatted())"
        }
        return chosen
    }

    private var groupSheet: some View {
        ScrollView {
            ChannelGroupSheet(
                routes: GroupPath.routes(from: model.groups),
                total: model.visibleCount,
                chosen: model.chosen
            ) { group in
                isGroupSheetOpen = false
                // **`select` toggles when the same group comes.** From the sheet
                // that is wrong: whoever presses the row that is already chosen
                // confirms it and does not deselect it.
                if group != model.chosen { model.select(group: group) }
            }
            .padding(.vertical, MetricsBoard.phone.gutter)
        }
        .presentationDetents([.fraction(SheetID.channelGroups.portion), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
        .presentationBackground(ColorRole.surfaceHigh.color)
    }

    // MARK: - Sport

    @ViewBuilder
    private func schedule(_ sport: SportModel) -> some View {
        switch sport.state {
        case .isLoading:
            LoadingState(message: "sport.loading").frame(maxHeight: .infinity)

        case .withoutBacklog:
            // **An assignment and not information**, because there is exactly one next
            // step — and without it this area stays empty forever. "No sports today"
            // would simply be a lie here: nobody has looked.
            withoutBacklog

        case .empty:
            StateBlock(
                form: .info(
                    StateInfo(
                        icon: Glyph.Tab.live.outlined,
                        headline: "sport.empty.title", message: "sport.empty.text"))
            )
            .frame(maxHeight: .infinity)

        case .settled:
            VStack(alignment: .leading, spacing: 0) {
                ProgramAge(state: model.status, isRefreshing: model.isRefreshing) {
                    Task { await refreshBoth() }
                }
                .padding(.bottom, 4)

                SportFilter(
                    sports: sport.sports, channels: sport.channelRow,
                    selectedKind: sport.sportKind, selectedChannel: sport.channels,
                    total: sport.all.count,
                    rememberFilter: sport.rememberFilter,
                    bookmarked: sport.count(.bookmarked), taken: sport.count(.taken),
                    selectKind: { sport.select(sportKind: $0) },
                    selectChannel: { sport.select(channels: $0) },
                    selectBookmarkFilter: { sport.select(rememberFilter: $0) })

                SportList(
                    segments: sport.segments(um: now),
                    channelName: { sport.channelName($0) },
                    watchlist: sport.watchlist,
                    now: now,
                    matches: playSport,
                    memorize: { sport.toggleMatch($0) },
                    followClub: { sport.episode(club: $0) },
                    followCompetition: { sport.episode(competition: $0) })
            }
        }
    }

    /// The assignment "fetch the program first" — in the words of this area.
    /// The schedule without a program guide — **an assignment of its own, with its own
    /// loud button.**
    ///
    /// **Until 2026-09-26 this block lay over ``PlaybackPhase/notSetUpYet``**, only to
    /// inherit its floating bar: the loud button carried "Set up" and fetched the
    /// program. Since the state carries its own target (the setup), the same
    /// button would have led into the setup. The block therefore draws its bar itself —
    /// with the label that says what it does.
    private var withoutBacklog: some View {
        ZStack(alignment: .bottom) {
            StateBlock(
                form: .job(
                    Job(
                        icon: Glyph.refresh.name,
                        headline: "sport.noGuide.title", message: "sport.noGuide.text",
                        button: "sport.noGuide.button", target: .sync))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            FloatingBar {
                Button {
                    Task { await refreshBoth() }
                } label: {
                    Text(app: "sport.noGuide.button").frame(maxWidth: .infinity)
                }
                .buttonStyle(.loud)
            }
        }
    }

    /// **One reconciliation for both sides.** Channels and schedule read the same cache;
    /// fetching twice would be the same file twice.
    private func refreshBoth() async {
        await model.fresh()
        await sport?.load(um: now)
    }

    /// Play a channel — **and write it into "Recently watched" beforehand.**
    ///
    /// The note lives here and not in the player: the app's history is for movies, and
    /// a channel expressly does not belong there. The handle that this list
    /// answers is a different one — "my channel", and that arises on selection.
    private func playAndRemember(_ channel: Channel) {
        model.note(channel)
        playChannel(channel)
    }

    /// Play a game — **via a visible channel and with an entry in "Recently
    /// watched"**, as on the TV (Live check, finding 6).
    private func playSport(_ event: SportEvent) {
        guard let channel = model.channels(forSport: event) else { return }
        playAndRemember(channel)
    }

    private var segment: some View {
        LiveSegment(
            channels: model.visibleCount, sport: sport?.all.count ?? 0,
            isSportSelected: $isSportSelected)
    }
}

/// Whether "Live" has already decided in this session via ``Flows/LiveEntry`` —
/// **once per program run**, as on the TV: whoever leaves the player gets the
/// overview, and that is the way back.
@MainActor
enum LiveJump {
    static var done = false
}
