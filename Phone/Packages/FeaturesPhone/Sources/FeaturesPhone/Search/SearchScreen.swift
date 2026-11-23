import Core
import DesignSystemPhone
import Flows
import Foundation
import NetworkStatus
import SwiftUI

/// Tab 5: across all catalogs at once.
///
/// **The only place that promises completeness across sources** — the register
/// does so within the library, here it applies to everything. That is why every group stays
/// visible even if it did not answer.
public struct SearchScreen: View {

    @State private var model: SearchViewModel

    /// In which width class drawing happens — see ``MetricClass``.
    ///
    /// **Via the class and never via the device.** An iPad at half width gets
    /// the compact class with an unchanged device ID; there the list is right and
    /// a grid would not be.
    @Environment(\.horizontalSizeClass) private var widthClass

    /// Where the device currently is — see ``LocationMonitor``.
    ///
    /// **Default `unknown` and not `home`** (AP6): until 2026-09-10. `.home` was hard-coded
    /// in the body here. Whoever was out and about read a statement about their network
    /// that came from one line of code. With an unknown location no location line is shown.
    var location: LocationStatement.Location = .unknown

    private let account: String
    private let onAccountTap: () -> Void
    /// The way to Favorites — **`nil` if they sit at the bottom of the bar.**
    ///
    /// With the full setup the bar is full, and Favorites move to the top
    /// (``CatalogState/favoritesAtBottom``). Without this heart they would be reachable from
    /// **nowhere** — the tab is missing precisely for that reason.
    private let onFavoritesTap: (() -> Void)?
    /// Open a hit — **with its origin.**
    ///
    /// **The origin has to travel along, otherwise a channel hit cannot be tapped.** It
    /// sits on the group it comes from (``ResultBundle/origin``), and without it
    /// every hit would land on the Jellyfin detail page — for a channel a
    /// screen that does not exist. The same reasoning as for ``PlaybackJob``: a
    /// channel ID carries no feature by which it could be recognised.
    private let open: (TileContent, Catalog.Origin) -> Void
    /// The side path under "nothing found": **"Search in Live".**
    private let searchInLive: () -> Void

    /// Where the long-press commands get their answer — see ``TileCommands``.
    ///
    /// `nil` means **no menu**; the reasoning is at ``TitleGrid/commandSource``.
    private let commandSource: (any DetailSource)?
    /// The state of a hit in the downloads — `nil` where no downloads are kept.
    private let downloadState: ((String) -> DownloadState?)?
    /// Opens the download sheet for a hit — `nil` as long as nobody can open it.
    private let load: ((TileContent) -> Void)?

    public init(
        sources: [any SearchSource],
        networkMonitor: NetworkStatus.NetworkWatch? = nil,
        searchInLive: @escaping () -> Void = {},
        account: String = "?",
        onAccountTap: @escaping () -> Void = {},
        onFavoritesTap: (() -> Void)? = nil,
        open: @escaping (TileContent, Catalog.Origin) -> Void = { _, _ in },
        commandSource: (any DetailSource)? = nil,
        downloadState: ((String) -> DownloadState?)? = nil,
        load: ((TileContent) -> Void)? = nil,
        location: LocationStatement.Location = .unknown
    ) {
        self.location = location
        _model = State(initialValue: SearchViewModel(sources: sources, networkMonitor: networkMonitor))
        self.account = account
        self.onAccountTap = onAccountTap
        self.onFavoritesTap = onFavoritesTap
        self.open = open
        self.searchInLive = searchInLive
        self.commandSource = commandSource
        self.downloadState = downloadState
        self.load = load
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

                headerBlock

                content
            }
        }
        .task {
            // **`CINELOUNGE_SUCHE=drugladan` types for the simulator.** A test hook, not a
            // feature: the simulator accepts no keystrokes from outside, and
            // a search without input cannot be checked. The same pattern as
            // `CINELOUNGE_ZUSTAND`, `CINELOUNGE_LIVE` and `CINELOUNGE_PROGRAMM`.
            if let preset = ProcessInfo.processInfo.environment["CINELOUNGE_SUCHE"],
                !preset.isEmpty
            {
                model.word = preset
            }
        }
    }

    /// Title, search field, location line — **the column that is typed into.**
    ///
    /// **On the iPad it is capped, the result area below it is not** (AP7,
    /// 2026-09-23). These are two different things: here you write and read,
    /// below you browse. A search field 992 points wide has its clear cross
    /// **half a metre** from the word just typed — the finding from the device —,
    /// while a poster grid lives precisely on the area that harms the field. That is why
    /// one takes ``MetricClass/contentCap(_:)`` and the other the full width.
    ///
    /// **The title moves along and does not stay at the left edge.** A large title that
    /// starts 166 points to the left of its own search field looks like an accident;
    /// a coherent block looks intentional. What remains is the seam
    /// between the centred block and the edge-wide grid below — the same seam
    /// that every Home screen with centred input over wide content has.
    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            LargeTitle(title: "tab.search")
                .padding(.horizontal, MetricsBoard.phone.margin)

            SearchField(text: $model.word, placeholder: "search.placeholder")
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.bottom, 10)

            LocationRow(statement: LocationStatement.forItem(.search, location: location))
        }
        // **Cap and centre belong together — otherwise the block pins to the left.** The
        // reasoning is given at length in ``SettingsScreen``; the rule is guarded
        // by ``whoeverCapsAlsoCenters()``.
        .frame(maxWidth: MetricClass.contentCap(widthClass) ?? .infinity)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            SearchEmpty(hasInput: false, word: model.word)
        case .isSearching:
            LoadingState(message: "search.running").frame(maxHeight: .infinity)
        case .nothingFound:
            SearchEmpty(hasInput: true, word: model.word, searchInLive: searchInLive)
        case .disrupted(let state):
            // **Nothing was searched anywhere** — that is why there is no empty screen here,
            // but a disturbance with its next step.
            StateView(state: state, action: { model.retry() })
        case .settled:
            // **The width is measured and not assumed** — the same construction as in the
            // ``TitleGrid``. The tile width follows from it; guessing it from a
            // device ID is exactly the mistake ``MetricClass`` was
            // written against. It is measured **once** for all groups: four
            // catalogs would otherwise give four measurements of the same value.
            GeometryReader { surface in
                let raster = SearchGrid.forItem(width: surface.size.width, sizeClass: widthClass)
                ScrollSurface {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.groups) { sharedStore in
                            ResultGroup(
                                sharedStore: sharedStore,
                                open: { match in open(match.tile, sharedStore.origin) },
                                commandSource: commandSource, downloadState: downloadState,
                                load: load, following: { model.retry() }, raster: raster)
                        }
                    }
                    .padding(.top, Metrics.targetSpacing)
                }
            }
        }
    }
}

/// Nothing entered and nothing found — **two screens.**
///
/// One says what is searched here; the other that there is nothing for this word.
/// Merging them would mean telling someone on opening that nothing was found
/// — before they have searched.
///
/// **No search history.** The TV has none either, and here it would be an
/// additional store about something you can repeat in two keystrokes. What someone
/// searched for also says more about them than a media app should store.
/// Nothing entered, nothing found — **two different screens.**
///
/// No search history; the TV has none either.
///
/// **Until 2026-09-07 the explanation was in a file of its own** — `SearchEmpty.swift`, six
/// lines of comment and no type, while the type lay here. That breaks "One file per
/// thing" twice over: the thing has two files, and one of them has no thing.
/// The second consequence was worse: the sentence "Not built yet" stood there above something
/// finished and made the entry useless as an inventory.
struct SearchEmpty: View {

    let hasInput: Bool
    let word: String

    /// What the quiet path under "nothing found" does — **"Search in Live".**
    ///
    /// ``PlaybackPhase/emptySearch`` has named it since E17 and nobody served it; it was drawn
    /// anyway. Since 2026-09-06. ``StateBlock`` draws a side path only if
    /// someone serves it — here is the server.
    var searchInLive: () -> Void = {}

    var body: some View {
        Group {
            if hasInput {
                // **``PlaybackPhase/emptySearch`` and not a rebuilt block.** The state has been in the list
                // since E17 and had not a single producer, while this file wrote its content
                // alongside it — two versions of the same sentence
                // that drift apart as soon as someone improves one.
                StateBlock(form: PlaybackPhase.emptySearch.form, secondaryAction: searchInLive)
            } else {
                StateBlock(
                    form: .info(
                        StateInfo(
                            icon: Glyph.Tab.search.outlined,
                            headline: "search.idle.title", message: "search.idle.text")))
            }
        }
        .frame(maxHeight: .infinity)
    }
}
