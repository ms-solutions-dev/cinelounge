import Core
import DesignSystemPhone
import Flows
import Observation
import SwiftUI

/// Tab 4 · Favorites — **the screen that did not exist.**
///
/// **It stood as a tab in the bar and in no package of the roadmap.** Found on
/// 2026-09-06 by counting the paths: `CatalogState.tabs` produces it, `Tab.favorites`
/// has icon and title, and ``TabPlaceholder`` had no branch — whoever
/// tapped it got "favoriten · noch nicht gebaut" along with three developer buttons. One tab
/// of five, and none of the 130 findings of the pass mentioned it.
///
/// **It is not in the design either.** 43 views are operable there; this one is not
/// among them. There are stars **on rows** and the sentence that favorites belong to the account —
/// the place where they come together does not exist. What stands here is therefore derived from the
/// reason why `CatalogState` creates the tab at all: it is **the
/// only one that fits every setup**. So it shows what has a star — from
/// every source that yields one.
///
/// **Sections per source and no common stack.** A media server answers in
/// milliseconds, a portal asks a third-party service, and a channel is not a title at all.
/// The same reasoning as in search: what comes from where decides whether you
/// press.
///
/// **A channel plays, everything else opens** — the same switch as in Home and Search,
/// and for the same reason: a channel has no detail page, it has a picture.
public struct FavoritesScreen: View {
    /// **Three columns on the phone, six on the iPad** — see ``MetricClass``.
    @Environment(\.horizontalSizeClass) private var widthClass

    @State private var model: FavoritesViewModel

    /// How wide a tile is — **measured and not assumed.**
    ///
    /// The same rule as in the register: a fixed width is either too narrow or too wide at every other
    /// screen width, and you see both immediately. Measuring happens **once** at the scroll area and not per section — a
    /// `GeometryReader` per grid would be the same number four times with four sources.
    @State private var tileWidth = MetricsBoard.phone.poster.width

    /// The same width for a wide grid — two columns instead of three.
    @State private var wideTileWidth = MetricsBoard.phone.episode.width

    private let account: String
    private let onAccountTap: () -> Void
    private let open: (TileContent, Catalog.Origin) -> Void

    /// Who sets the watched mark and favorite — see ``TileCommands``.
    ///
    /// **The heart takes something away here and adds nothing**, and that is exactly why
    /// the long press belongs on this screen: it is the place where you notice that something
    /// is remembered wrongly.
    private let commandSource: (any DetailSource)?

    /// How a title stands in the downloads — `nil` where no downloads are kept.
    private let downloadState: ((String) -> DownloadState?)?

    /// Opens the download sheet for a tile — see ``TileCommands/load``.
    private let load: ((TileContent) -> Void)?

    public init(
        sources: [any FavoritesSource],
        account: String = "?",
        onAccountTap: @escaping () -> Void = {},
        open: @escaping (TileContent, Catalog.Origin) -> Void = { _, _ in },
        commandSource: (any DetailSource)? = nil,
        downloadState: ((String) -> DownloadState?)? = nil,
        load: ((TileContent) -> Void)? = nil
    ) {
        _model = State(initialValue: FavoritesViewModel(sources: sources))
        self.account = account
        self.onAccountTap = onAccountTap
        self.open = open
        self.commandSource = commandSource
        self.downloadState = downloadState
        self.load = load
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(spacing: 0) {
                HeaderRow(
                    title: "tab.favorites", account: account, onAccountTap: onAccountTap
                )
                .padding(.bottom, MetricsBoard.phone.gutter)

                content
            }
        }
        // **Fresh on every appearance.** A star that someone set in the library
        // belongs here as soon as it comes back — a list from last time looks
        // right and is not. Until 2026-09-27 ``FavoritesViewModel/load()`` aborted
        // with a filled list and did not keep the promise of this row (check finding F2).
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.bundles.isEmpty {
            LoadingState(message: "favorites.loading").frame(maxHeight: .infinity)
        } else if model.isEmpty {
            // **Two empty cases and two sentences.** "Nothing remembered yet" is an
            // invitation; "no source has answered" is a fault. Treating them the same
            // would mean blaming the viewer for something that is the network's fault.
            StateView(
                state: model.disruption ?? .emptyFavorites,
                action: { Task { await model.load() } })
        } else {
            list
        }
    }

    private var list: some View {
        ScrollSurface {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.filledBundles) { bundle in
                    // **The name of the source and the number next to it.** "Media server · 12"
                    // answers at a glance what a section header without a number would leave
                    // open: whether it is worth scrolling there.
                    SectionHeader(
                        wording: bundle.headline.readable + " · "
                            + bundle.title.count.formatted())

                    grid(bundle)
                        .padding(.horizontal, MetricsBoard.phone.margin)
                        .padding(.bottom, MetricsBoard.phone.section)
                }

                // **What did not answer stands at the end and not in between.**
                // A fault message between two sections looks as if it belonged
                // to the next one.
                ForEach(model.quietBundles) { bundle in
                    HintRow(
                        icon: Glyph.offline.name, color: ColorRole.progress.color,
                        title: "favorites.silent",
                        wording: bundle.headline.readable)
                }
            }
            .padding(.top, MetricsBoard.phone.gutter)
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { fresh in
            guard fresh > 0 else { return }
            tileWidth = TitleGrid.tileWidth(at: fresh, sizeClass: widthClass)
            wideTileWidth = TitleGrid.tileWidth(at: fresh, wide: true, sizeClass: widthClass)
        }
    }

    /// **Three columns as in the register.** Whoever comes from the library finds the same
    /// tile size; a measure of its own here would mean that the same movie is two different
    /// sizes.
    ///
    /// **Decided per bundle and not per screen** (2026-09-07): a bundle is exactly the
    /// level that ``TileContent/isWideShelf(_:)`` is about — the favorites of a
    /// portal with wide images then stand wide, those of the media server above them stay
    /// tall. Decided over the whole view, a single wide image would drag all
    /// posters along.
    private func grid(_ bundle: FavoritesBundle) -> some View {
        let wide = TileContent.isWideShelf(bundle.title)
        return LazyVGrid(
            columns: [GridItem](
                repeating: GridItem(.flexible(), spacing: MetricsBoard.phone.gutter),
                count: wide
                    ? TitleGrid.wideColumnCount(widthClass) : TitleGrid.columnCount(widthClass)),
            spacing: Metrics.rowGap
        ) {
            ForEach(bundle.title) { tile in
                Button {
                    open(tile, bundle.origin)
                } label: {
                    PosterTile(
                        content: tile,
                        width: wide ? wideTileWidth : tileWidth,
                        wideFrame: wide)
                }
                .buttonStyle(.plain)
                // **No "Reset progress" here.** This screen shows
                // what is remembered and not what is started; the command would take a title out of a
                // shelf that does not stand here at all.
                .tileCommands(
                    tile, origin: bundle.origin, source: commandSource, inHistory: false,
                    downloadState: downloadState.flatMap { $0(tile.id) }, load: load,
                    following: { Task { await model.load() } })
            }
        }
    }

}

/// What is remembered — **from all sources, fetched concurrently.**
@MainActor
@Observable
public final class FavoritesViewModel {

    public private(set) var bundles: [FavoritesBundle] = []
    public private(set) var isLoading = false

    private let sources: [any FavoritesSource]

    public init(sources: [any FavoritesSource]) {
        self.sources = sources
    }

    /// The sections that have something to show.
    public var filledBundles: [FavoritesBundle] { bundles.filter { !$0.title.isEmpty } }

    /// The sources that did not answer.
    public var quietBundles: [FavoritesBundle] { bundles.filter { !$0.hasAnswered } }

    public var isEmpty: Bool { filledBundles.isEmpty }

    /// Whether **one** source stayed silent.
    ///
    /// **The difference is the whole point.** "Nothing remembered yet" is an invitation,
    /// "a source did not answer" a fault — and whoever treats both the same
    /// blames the viewer for something that is the network's fault.
    ///
    /// **One silent source suffices, not only all** (check finding F3, 2026-09-27): a silent
    /// media server next to a channel list without favorites yielded "Nothing remembered yet", and
    /// the notice line of the silent source stood only in the list, which was then missing.
    /// The same rule as in search (``Flows/Search``).
    public var noResponse: Bool { !quietBundles.isEmpty }

    /// The fault that the empty screen shows — after the first silent source.
    public var disruption: PlaybackPhase? {
        switch quietBundles.first?.origin {
        case nil: nil
        case .jellyfin?: .networkJellyfin
        case .portals?: .networkPortals
        default: .networkXtream
        }
    }

    /// Loads **every time** — on appearing, after a command, on pulling. The loading spinner
    /// stands only with an empty list (see ``FavoritesScreen``), so nothing flickers.
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        if let aggregate = sources.first as? CollectedFavorites, sources.count == 1 {
            bundles = await aggregate.bundles()
        } else {
            var collected: [FavoritesBundle] = []
            for source in sources { collected += await source.segments() }
            bundles = collected
        }
    }
}
