import DesignSystemPhone
import Flows
import SwiftUI

/// The catalog as a grid of posters — **the same shape for every source.**
///
/// **The text list was dropped on 2026-09-05, and three of its four justifications were
/// wrong.** It rested on "32,532 titles without a single poster" — recounted on the real
/// account, **53 of 53** titles of one category have a poster and a rating. It
/// calculated "eleven rows per screen instead of six"; measured, it is **7.9**, and 11 : 6
/// becomes 8 : 6, so density no longer carries a decision about form. And it claimed a
/// grid cannot carry a jump bar — the TV has always laid it over its grid.
///
/// What holds is the sentence "form follows the verb". Only the verb is not different:
/// in the provider catalog too, people **browse** — 108 categories are called "DE| KRIEGS
/// FILME", "4K UHD", "Weihnachten"; these are browsing bins. Lookups go through search,
/// not through six hundred screens.
///
/// **Three columns, no adaptive count.** An `.adaptive` grid computes to three at 393
/// points and to four at 440 — the same library would then look different on two
/// devices, and the poster width would shift with it. Three fixed columns keep the tile
/// the same size everywhere and thus the image request at one size.
struct TitleGrid: View {

    /// **Three columns on the phone, six on the iPad** — see ``MetricClass``.
    @Environment(\.horizontalSizeClass) private var widthClass

    let order: Order
    let open: (TileContent) -> Void

    /// Called as soon as the **last** tile comes into view.
    ///
    /// `nil` for everything that is fully loaded — and that is everything except the
    /// portals: a media server delivers its catalog in one piece, a provider too. Only a
    /// portal hands out its catalog page by page, and only the ARD Mediathek really does.
    var atEnd: (() -> Void)?

    /// Where the long-press commands get their answer — see ``TileCommands``.
    ///
    /// **The finding of 2026-09-09, from the client:** *"when I am in the library and press a
    /// title for longer, I should have options like 'download' or 'favorite' or
    /// similar."* The component was attached to Home, portals and favorites — in the
    /// library grid it did not exist.
    ///
    /// **`nil` means: no menu at all**, and not "a menu without effect". Without a source,
    /// the watched mark and favorite could not ask anyone; a long press that pulls up a
    /// menu and then does nothing is worse than one that pulls up nothing. This is also why
    /// the portal page stays unchanged: it builds the same grid and brings its commands
    /// along itself elsewhere.
    var commandSource: (any DetailSource)?

    /// Where the tile learns whether it is already in the downloads — per identifier.
    var downloadState: ((String) -> DownloadState?)?

    /// Opens the download sheet — `nil` if this screen cannot do it.
    var load: ((TileContent) -> Void)?

    /// An **optional handle** on the identifier of the topmost visible tile — see
    /// ``ScrollSurface/location``.
    ///
    /// **The same as in the portals' folder list, and from the same finding of 2026-09-09**
    /// Whoever goes one level down from a mixed portal level and comes back finds the grid
    /// at the very top again otherwise: SwiftUI switches the branch in the process, tears
    /// this surface down and builds a new one on return.
    ///
    /// **A string and not a `ScrollPosition`** (improved on 2026-09-09). Why the first version
    /// could not hold is explained at ``ScrollSurface/location``: a `ScrollPosition()` without
    /// an identifier type only carries an offset, and an offset on a surface that does not
    /// exist yet is not a position.
    ///
    /// **`nil` means as everywhere: the surface keeps its position itself.** The library
    /// does not need the handle — it stays put when descending, because the detail page is
    /// laid over it and does not take its place.
    var location: Binding<String?>?

    /// Reload after a change.
    var following: () -> Void = {}

    /// **Three on the phone, six on the iPad** — the number comes from ``MetricClass``.
    ///
    /// Here `3` stood as a fixed value, and that was right at 393 points. At 1032 points the
    /// **tile** grew to 323 points instead of the **count** — 8.6 times in area. The full
    /// reasoning is at ``MetricClass``.
    static func columnCount(_ sizeClass: UserInterfaceSizeClass?) -> Int {
        MetricClass.columns(sizeClass)
    }

    /// This many columns does a **wide** grid have.
    ///
    /// **Two and not three.** Three 16 : 9 tiles side by side are 110 wide at 393 points and
    /// **62 high** — nothing can be made out in that, and the caption below would be taller
    /// than the image. With two columns it is 178 × 100, which is the size in which the TV
    /// shows its episode cards.
    static func wideColumnCount(_ sizeClass: UserInterfaceSizeClass?) -> Int {
        MetricClass.wideColumns(sizeClass)
    }

    /// Whether this level is drawn wide — the rule is at
    /// ``TileContent/isWideShelf(_:)``.
    private var wide: Bool { TileContent.isWideShelf(order.entries) }

    /// The jump bar appears from this many titles.
    ///
    /// **Twenty-four, like on the TV.** Below that a jump is shorter than a swipe, and then
    /// the control costs more than the problem. This also makes it appear for the media
    /// server — 103 films are twelve screens —, and that is right: it was never a feature of
    /// the provider.
    static let barFrom = 24

    private static func columns(_ sizeClass: UserInterfaceSizeClass?) -> [GridItem] {
        [GridItem](
            repeating: GridItem(.flexible(), spacing: MetricsBoard.phone.gutter),
            count: columnCount(sizeClass)
        )
    }

    private static func wideColumns(_ sizeClass: UserInterfaceSizeClass?) -> [GridItem] {
        [GridItem](
            repeating: GridItem(.flexible(), spacing: MetricsBoard.phone.gutter),
            count: wideColumnCount(sizeClass))
    }

    private var hasBar: Bool {
        order.entries.count >= Self.barFrom && order.marks.count > 2
    }

    var body: some View {
        // **The width is computed, not left to chance.** Seen on screen: with
        // `aspectRatio` in the grid cell the posters were **not on one line** —
        // a two-line caption makes the cell taller, and the image area aligned
        // to that instead of to its width. A grid turned into a staircase.
        //
        // With a computed width every tile is the same size, every image is requested in
        // **one** size, and the rows line up.
        GeometryReader { surface in
            let width = Self.tileWidth(
                at: surface.size.width, wide: wide, sizeClass: widthClass)
            ScrollViewReader { controller in
                ZStack(alignment: .trailing) {
                    // **Without `bottomClearance`, because the sort row hangs via `safeAreaInset`**
                    // (``LibraryScreen/bar``): it is thus already in the
                    // safe area, and the scroll-to-top button avoids it by itself. An addition here would
                    // be the third accounting of the same bar.
                    // **The button yields to the jump bar** (AP7, 2026-09-23):
                    // it holds a 44-point grab strip on the right and lies above it in this
                    // stack, so it won every tap on the middle of the button.
                    ScrollSurface(location: location, scrollToTopCorner: .bottomLeading) {
                        LazyVGrid(
                            columns: wide ? Self.wideColumns(widthClass) : Self.columns(widthClass),
                            alignment: .leading, spacing: Metrics.rowGap
                        ) {
                            ForEach(order.entries) { entry in
                                withCommands(entry) {
                                    Button {
                                        open(entry)
                                    } label: {
                                        PosterTile(
                                            content: entry, width: width,
                                            wideFrame: wide)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .id(entry.id)
                                // **At the last entries, counted from the end** (AP76,
                                // ``Flows/LoadMore``). Until then only at the very last: whoever
                                // reached the bottom waited for the next page. Twelve from the end
                                // do not need the grid width; `onAppear` is still called multiple
                                // times — the guard against that lives in the model.
                                .onAppear {
                                    if LoadMore.applies(entry, in: order.entries) {
                                        atEnd?()
                                    }
                                }
                            }
                        }
                        // **So that the remembered position is a row and not an offset.**
                        // An offset on a surface that does not yet exist on return is not a
                        // position; via the tile's identifier even a freshly built surface
                        // finds the same row again. The identifier is set at the bottom by
                        // `.id(entry.id)`, which exists here anyway for the jump bar.
                        .scrollTargetLayout()
                        .padding(.leading, MetricsBoard.phone.margin)
                        .padding(.trailing, Self.rightEdge)
                        .padding(.top, MetricsBoard.phone.gutter)
                        .padding(.bottom, Metrics.bottomInsetWithBar)
                    }
                    // **The letters for the screen reader too.** The bar itself is
                    // invisible to it — it is a dragged element and is unsuited for that.
                    // Without the rotor, the only option there would be to swipe right
                    // 4,211 times.
                    // **Without `if let` in the body.** Since Xcode 27 an optional
                    // rotor entry only compiles with macOS 27 — the test suite runs on
                    // the Mac. The marks without a target are sorted out beforehand, and the
                    // body stays one entry per mark.
                    .accessibilityRotor(Text(app: "library.letters")) {
                        ForEach(order.marks.filter { order.targets[$0] != nil }, id: \.self) {
                            tag in
                            AccessibilityRotorEntry(tag, id: order.targets[tag] ?? tag)
                        }
                    }

                    if hasBar {
                        JumpBar(marks: order.marks) { tag in
                            guard let target = order.targets[tag] else { return }
                            // **Without animation.** A jump across three thousand tiles that
                            // can be animated visibly scrolls through everything in between —
                            // with 4,211 titles that is seconds in which nobody
                            // recognizes anything.
                            controller.scrollTo(target, anchor: .top)
                        }
                    }
                }
            }
        }
    }

    /// The tile with the long press — or without, if nothing can answer it.
    ///
    /// **No "reset progress" in the grid.** The library is not a
    /// Continue Watching shelf; the command would take a title out of a shelf that is not
    /// even there — the same wording as for favorites.
    ///
    /// **The origin is attached to the identifier** and is not passed in from outside: in
    /// this grid, depending on the chosen catalog, there are titles of the media server, of
    /// the provider or of a portal, and ``PlaybackJob/origin(zu:)`` is the one place that
    /// decides this.
    @ViewBuilder
    private func withCommands(
        _ entry: TileContent, @ViewBuilder _ tile: () -> some View
    ) -> some View {
        if commandSource != nil || load != nil {
            tile()
                .tileCommands(
                    entry, origin: nil, source: commandSource, inHistory: false,
                    downloadState: downloadState.flatMap { $0(entry.id) }, load: load,
                    following: following)
        } else {
            tile()
        }
    }

    /// The right edge — **always the full one, even without a visible bar.**
    ///
    /// Otherwise there would be two tile widths and thus two requested image sizes: when
    /// switching the ordering or when filtering below twenty-four titles, every poster
    /// would be fetched a second time. Eighteen points cost less than a second image
    /// version in memory.
    static let rightEdge: CGFloat = JumpBar.slot + 2

    /// - Parameter breit: whether the level draws 16 : 9 — then it is two columns instead of
    ///   three. The default `false` keeps every caller valid that only knows posters.
    static func tileWidth(
        at total: CGFloat, wide: Bool = false, sizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        let columns = CGFloat(wide ? wideColumnCount(sizeClass) : columnCount(sizeClass))
        let unrestricted =
            total - MetricsBoard.phone.margin - rightEdge - (columns - 1) * MetricsBoard.phone.gutter
        return max(60, (unrestricted / columns).rounded(.down))
    }
}
