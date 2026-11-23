import Core
import DesignSystemPhone
import ParentalControls
import ProfileKit
import SwiftUI

/// Tab 1: the header area and the shelves.
public struct StartView: View {
    /// **Three columns on the phone, six on the iPad** — see ``MetricClass``.
    @Environment(\.horizontalSizeClass) private var widthClass

    /// How often a manual refresh has happened — **only so that the haptics have a state.**
    /// A `Bool` flipped back on the second pull and reported nothing.
    @State private var refreshCount = 0

    @State private var model: StartModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The form factor — **larger posters in the kids UI** (G3, finding B3;
    /// ``Styling/Surface``), set by the shell.
    @Environment(\.surface) private var surface
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverActive

    /// How tall the header box has actually become — reported by ``BoxHeight``.
    ///
    /// **It grows and never shrinks.** Having a different height between two pages of the
    /// box would mean it jumps while paging; the largest reported height is therefore used.
    @State private var boxHeight: CGFloat = 0

    /// How wide a shelf tile is here — **measured and not hard-coded** (AP4).
    ///
    /// The default is the old fixed size: it applies for exactly one layout pass, until the
    /// first measurement arrives, and is thereby closer to the truth than a zero.
    /// It is measured **once at the scroll area** and not per shelf — see
    /// ``ShelfMetrics``.
    @State private var shelfWidth = MetricsBoard.phone.poster.width
    @State private var wideShelfWidth = MetricsBoard.phone.episode.width

    /// Whether the auto-advance is paused.
    ///
    /// **WCAG 2.2.2 requires a way to pause anything that moves by itself for longer than
    /// five seconds** — a visible one, not only the system switches. Until 2026-09-06 there were
    /// only the system switches, and anyone who had not set them could not pause the box.
    @State private var halted = false
    private let account: String
    private let onAccountTap: () -> Void
    /// The way to Favorites — **`nil` if they sit at the bottom of the bar.**
    ///
    /// With the full setup the bar is full, and Favorites move to the top
    /// (``CatalogState/favoritesAtBottom``). Without this heart they would be reachable from
    /// **nowhere** — the tab is missing precisely for that reason.
    private let onFavoritesTap: (() -> Void)?
    /// The way into the downloads — `nil` as long as there are none.
    private let onDownloadsTap: (() -> Void)?
    /// What a press on a tile or the header box does.
    ///
    /// **It is called `open` and not `play`** (decision of 2026-09-05). It never played
    /// anything — the shell uses it to open the detail page — and the old name was at the
    /// same time the justification for a play button in the header box that nobody needed.
    /// A name that claims something other than what the code does eventually builds its own
    /// view.
    /// **With the origin**, otherwise a channel tap cannot be tapped.
    ///
    /// Until 2026-09-06 every tile went to `.detail`, and a channel from "Live today" thereby
    /// landed on the Jellyfin detail page, which does not know its ID.
    /// `nil` means "judge by the ID" — see ``StartModel/origin(zu:)``.
    private let open: (TileContent, Catalog.Origin?) -> Void
    /// Continues a Continue Watching tile in place — `nil` means: it opens like any other.
    /// See ``TileContent/playsInHistory``.
    private let resume: ((TileContent, Catalog.Origin?) -> Void)?
    /// "Details" from the long press in Continue Watching — the series page, even where
    /// the source first has to look for it. `nil` means: like an ordinary open.
    private let toSeries: ((TileContent, Catalog.Origin?) -> Void)?
    private let onTargetTap: () -> Void
    /// Where playback happens — only for the symbol in the header row.
    private let target: PlaybackDestination

    /// The way into the catalog register — **its own closure and not the one of the destination.**
    ///
    /// **Until 2026-09-12 it was the same one.** "All catalogs" at the bottom of Home and
    /// the playback destination in the header row both called ``onTargetTap``, and the
    /// shell attached the destination sheet to it: anyone who pressed "All catalogs" at the
    /// bottom got the question of where to play. Two buttons on one closure are not a saving
    /// but a mix-up that nobody sees in the source — both lines read correctly.
    private let tabPressed: () -> Void

    /// Who sets the watched mark and the favorite — see ``TileCommands``.
    ///
    /// **The same source as the detail page, and not a second one.** It decides by ID who is
    /// asked; a separate path from here would be a second truth about who owns a title.
    private let commandSource: (any DetailSource)?

    /// The state of a title in the downloads — `nil` where no downloads are kept.
    private let downloadState: ((String) -> DownloadState?)?

    /// Opens the download sheet for a tile — `nil` as long as nobody can open it.
    ///
    /// **The finding of 2026-09-09:** "Download" was missing from the long press in every single
    /// place. The path there is built and used by the detail page; all that is needed is that
    /// the view that can open the sheet passes it through — see ``TileCommands/load``.
    private let load: ((TileContent) -> Void)?

    /// - Parameter vorliebenLaden: Where the order, hidden items and hero choice come from.
    ///
    ///   **Until 2026-09-07 it was not passed through**, and `Presentation → Regale isArranging` thus
    ///   had no effect: ``StartModel`` took the default `{ .preset }`, which knows neither an
    ///   order nor a hidden shelf. It went unnoticed because all switches are on in the
    ///   product owner's setup — a screen that does nothing exactly when nothing was changed.
    ///
    ///   **A handle and not a value**, so that ``StartModel/load()`` reads fresh on every
    ///   return — the same agreement as for ``TodayLive`` and
    ///   ``JellyfinStartSource``.
    public init(
        source: (any StartSource)?,
        ratings: (any RatingSource)? = nil,
        catalogs: CatalogState = .fromAccesses(jellyfin: true),
        loadPreferences: (@Sendable () -> StartPreferences)? = nil,
        portalPreferences: (@Sendable () -> PortalPreferences)? = nil,
        account: String = "?",
        onAccountTap: @escaping () -> Void = {},
        target: PlaybackDestination = .phone,
        onFavoritesTap: (() -> Void)? = nil,
        onDownloadsTap: (() -> Void)? = nil,
        open: @escaping (TileContent, Catalog.Origin?) -> Void = { _, _ in },
        resume: ((TileContent, Catalog.Origin?) -> Void)? = nil,
        toSeries: ((TileContent, Catalog.Origin?) -> Void)? = nil,
        onTargetTap: @escaping () -> Void = {},
        tabPressed: @escaping () -> Void = {},
        commandSource: (any DetailSource)? = nil,
        downloadState: ((String) -> DownloadState?)? = nil,
        load: ((TileContent) -> Void)? = nil,
        rule: ProtectionRule = .pending
    ) {
        _model = State(
            initialValue: StartModel(
                source: source, ratings: ratings, catalogs: catalogs,
                loadPreferences: loadPreferences, portalPreferences: portalPreferences,
                rule: rule))
        self.account = account
        self.onAccountTap = onAccountTap
        self.target = target
        self.onFavoritesTap = onFavoritesTap
        self.onDownloadsTap = onDownloadsTap
        self.open = open
        self.resume = resume
        self.toSeries = toSeries
        self.onTargetTap = onTargetTap
        self.tabPressed = tabPressed
        self.commandSource = commandSource
        self.downloadState = downloadState
        self.load = load
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            switch model.state {
            case .isLoading:
                LoadingState(forItem: .loadingStart)
                    .frame(maxHeight: .infinity)

            case .disrupted(let state):
                // **The loud button had no job until 2026-09-06**
                // ``StateView`` draws it as soon as the state is a ``Job``
                // and then calls `action?()` — an action that nobody had set at four of five
                // call sites. A button that does nothing when pressed is worse than none: it claims
                // there is a way.
                //
                // **The way here is the same as everywhere: load again.** Every
                // error state of this view comes from a failed fetch, and
                // ``StartModel/load()`` resets `state` itself in the process.
                StateView(state: state, action: { Task { await model.load() } })

            case .empty:
                empty.frame(maxHeight: .infinity)

            case .settled:
                content
            }
        }
        .task { await model.load() }
        // **New as soon as something arrives from the cloud** (2026-09-29) — as on the TV.
        // Progress, channel history and Home order from another device otherwise only showed up
        // after the next open or pull-down.
        .onReceive(NotificationCenter.default.publisher(for: ProfileCloud.arrived)) { _ in
            Task { await model.load() }
        }
        // **The second way into the downloads, and it costs no tab** (requested on
        // 2026-09-08: in addition to the button, swiping right (i.e. left of
        // Home) should also open the downloads area; no entry in the
        // navigation bar is needed for this).
        //
        // **It does not replace the button.** A gesture is invisible — whoever does not know it
        // finds the area only via the header row; whoever knows it is faster. The
        // rule for when it applies is at ``EdgeSwipe``.
        .edgeSwipe(onDownloadsTap)
        // **Pulling synchronises — since 2026-09-08 and explicitly.** Until then this said
        // the opposite: "Pulling refreshes, it does not synchronise", because a
        // gesture that is triggered by accident while scrolling should not do the most expensive
        // thing the app can do. That sentence applied to an arbitrary gesture and not to this one:
        // pull to refresh only takes effect at the top end and only beyond a distance that
        // nobody covers in passing.
        //
        // **And it costs a button that is thereby no longer needed.** The
        // sync button was in ``HeaderRow`` and is gone from there; its place belongs to the
        // downloads. What it did, this gesture now does — see ``StartModel/refresh()``.
        //
        // **The haptics hang on the counter and not on the call.** `refreshable` brings none
        // itself, and the result is exactly the case of ``Haptics/Occasion/succeeded``:
        // nothing happens for seconds, and afterwards the same list is there with different
        // content.
        .refreshable {
            await model.refresh()
            refreshCount += 1
        }
        .haptics(.succeeded, at: refreshCount)
    }

    private var empty: some View {
        StateView(
            state: .emptyLibrary, action: { Task { await model.load() } })
    }

    private var content: some View {
        ScrollSurface {
            VStack(alignment: .leading, spacing: 0) {
                HeaderRow(
                    account: account, onAccountTap: onAccountTap,
                    onTargetTap: onTargetTap, target: target,
                    onFavoritesTap: onFavoritesTap,
                    // **Only on Home.** It exists in every setup — that
                    // was the reason to put the downloads here and not in the bar
                    // (E13: "With 'portals only' the downloads are unreachable"). Placing them
                    // additionally in Library, Live, Portals and Search would mean
                    // four further ways to the same place.
                    onDownloadsTap: onDownloadsTap
                )
                .padding(.bottom, 12)

                headerArea

                ForEach(model.visibleShelves) { shelf in
                    shelfRow(shelf)
                }

                if model.hasMultipleCatalogs {
                    allCatalogs
                }
            }
            // Inset for the tab bar — otherwise the last row of tiles
            // behind it disappears, and nobody misses it because it was never visible.
            .padding(.bottom, Metrics.bottomInset)
            // **The width comes from the container, not from the content.** Without this line
            // the widest child determines the width, and a shelf full of tiles is
            // wider than the screen.
            .containerRelativeFrame(.horizontal)
        }
        // **Once for all shelves.** A `GeometryReader` per shelf row would be the same
        // number eight times for eight shelves — the same consideration as in ``FavoritesScreen``.
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { fresh in
            guard fresh > 0 else { return }
            shelfWidth = ShelfMetrics.tileWidth(at: fresh, sizeClass: widthClass)
            wideShelfWidth = ShelfMetrics.tileWidth(at: fresh, wide: true, sizeClass: widthClass)
        }
    }

    /// The box with the dots below it.
    ///
    /// **Swiping happens in the ``Pager``.** The dots are still their own: the
    /// built-in ones sit in the box, and there they would be a decoration on the image
    /// instead of a control below it.
    ///
    /// **After every swipe the clock restarts.** `task(id:)` cancels as soon as the
    /// standing hero changes — even when the thumb changed it. Without this the
    /// box advanced by itself two seconds after a swipe, and that is exactly what reads
    /// as a bug.
    @ViewBuilder
    private var headerArea: some View {
        let box = HeaderImage(content: model.headerTitle, open: open)
        let height = max(boxHeight, box.minHeight)

        VStack(spacing: 10) {
            if model.heroes.count > 1 {
                Pager(
                    elements: model.heroes, settled: $model.held, height: height
                ) { held in
                    HeaderImage(content: held, open: open)
                        .padding(.horizontal, MetricsBoard.phone.margin)
                }

                dotRow
            } else if model.headerTitle != nil {
                box.padding(.horizontal, MetricsBoard.phone.margin)
            }
            // **No box is better than an empty one.** With ``HeroLadder/Tier/nowOnAir``
            // this would show the current programme of three chosen channels — different content,
            // same place, same job. The channels for it have existed since the
            // Live package; **the "Live today" shelf now answers the same question
            // one row further down**, and two screens for one piece of information would be one
            // too many. The spot therefore stays empty instead of showing a construction site.
        }
        .padding(.bottom, MetricsBoard.phone.section)
        // **Not `onPreferenceChange` with a direct assignment.** The callback is
        // `@Sendable` and does not run on the main queue; writing from there would be an
        // error under strict concurrency.
        .onPreferenceChange(BoxHeight.self) { measured in
            Task { @MainActor in
                if measured > boxHeight { boxHeight = measured }
            }
        }
        .task(id: PagingState(held: model.held, halted: halted)) {
            await advancePaging()
        }
    }

    /// What the auto-advance hangs on: **the standing hero and the pause button.**
    ///
    /// Without the button in the key the clock would run out once more after pausing and
    /// advance one last time — exactly what the button is meant to prevent.
    private struct PagingState: Equatable {
        let held: Int
        let halted: Bool
    }

    /// The dots and the pause button next to them.
    ///
    /// **The button is only there where something moves.** With "Reduce Motion" and
    /// with VoiceOver running the box does not page anyway — a button that
    /// pauses something that stands still is a button without effect.
    @ViewBuilder
    private var dotRow: some View {
        HStack(spacing: Metrics.targetSpacing) {
            PageDots(count: model.heroes.count, settled: model.held)
            if !reduceMotion, !voiceOverActive {
                Button {
                    halted.toggle()
                } label: {
                    Image(systemName: halted ? Glyph.play.name : Glyph.pause.name)
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
                .target()
                .accessibilityLabel(Text(app: halted ? "home.resume" : "home.pause"))
            }
        }
    }

    /// Lets the header area page on once and ends there.
    ///
    /// The change alters the standing hero, and thereby `task(id:)` restarts this
    /// task — a loop without `while` that stops by itself when the view disappears.
    private func advancePaging() async {
        // **Not with "Reduce Motion" and not with VoiceOver running.** A
        // header area that advances by itself tears the VoiceOver focus out of the
        // line currently being read — and WCAG 2.2.2 requires a way to pause everything that
        // moves by itself for longer than five seconds.
        //
        // **And since 2026-09-06 there is the pause button for everyone** — visible next to the
        // dots, see ``dotRow``. Anyone who had set the system switches
        // had it anyway; everyone else had none until then.
        guard !reduceMotion, !voiceOverActive, !halted else { return }
        guard model.heroes.count > 1 else { return }
        try? await Task.sleep(for: StartModel.heroRotation)
        guard !Task.isCancelled else { return }
        model.nextHero()
    }

    @ViewBuilder
    private func shelfRow(_ shelf: Shelf) -> some View {
        let tiles = model.tiles[shelf.id] ?? []
        if tiles.isEmpty, let disruption = model.disruptions[shelf.id] {
            disruptedShelf(shelf, disruption)
        } else if shelf.form == .channelRow {
            channelShelf(shelf, tiles)
        } else {
            // **A portal shelf made of wide images gets a wide frame** (finding
            // of 2026-09-07). The rule decides the row for all its tiles
            // at once — ``TileContent/isWideShelf(_:)`` —, and it only applies where
            // the shelf carries posters anyway: "Live today" has its own form
            // for its own reason, and an image banner should not override that.
            let wide = shelf.form == .poster && TileContent.isWideShelf(tiles)
            ShelfRow(title: labeled(shelf.label), tally: "\(tiles.count)") {
                ForEach(tiles) { tile in
                    let isPlaying = playsOnTap(tile, in: shelf)
                    Button {
                        if isPlaying {
                            resume?(tile, model.origin(zu: tile.id))
                        } else {
                            open(tile)
                        }
                    } label: {
                        switch shelf.form {
                        case .poster:
                            PosterTile(
                                content: tile,
                                width: surface.enlarged(wide ? wideShelfWidth : shelfWidth),
                                wideFrame: wide)
                        case .wide: EpisodeTile(content: tile)
                        case .tag: BrandTile(content: tile)
                        // The vertical form is handled above and never arrives here; a
                        // `default` would give up the exhaustiveness of the `switch`, and
                        // that is exactly what should report when a form is added.
                        case .channelRow: EmptyView()
                        }
                    }
                    .buttonStyle(.plain)
                    // **The long press, as on the TV** (2026-09-07). It is on every
                    // tile and not only in the Continue Watching shelf — there only the
                    // third command is added; see ``TileCommands``.
                    .tileCommands(
                        tile, origin: model.origin(zu: tile.id), source: commandSource,
                        inHistory: shelf.id == StartPreferences.immovable,
                        downloadState: downloadState.flatMap { $0(tile.id) }, load: load,
                        details: isPlaying ? { showDetails(tile) } : nil,
                        following: { Task { await model.load() } })
                }
            }
        }
    }

    /// "Live today" — **vertical, as wide as the image** (objection W2).
    ///
    /// **No horizontal scrolling and therefore no count at the head.** What is there
    /// is there completely; a number next to it would answer a question nobody has.
    ///
    /// **The clock hangs around the shelf and not around the page.** The remaining time is shown
    /// in minutes, and redrawing the whole Home screen every minute would be the bug that
    /// was just fixed in the Live tab.
    private func channelShelf(_ shelf: Shelf, _ tiles: [TileContent]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: labeled(shelf.label))
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.bottom, 10)

            TimelineView(.periodic(from: .now, by: 60)) { cadence in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tiles) { tile in
                        LiveShelfRow(content: tile, now: cadence.date) { open(tile) }
                            .overlay(alignment: .bottom) {
                                if tile.id != tiles.last?.id {
                                    Divider().overlay(ColorRole.lineQuiet.color)
                                        .padding(
                                            .leading,
                                            MetricsBoard.phone.margin + Metrics.target
                                                + MetricsBoard.phone.gutter)
                                }
                            }
                    }
                }
            }
        }
        .padding(.bottom, MetricsBoard.phone.section)
    }

    /// A shelf that is not empty but disturbed — **and is therefore there.**
    ///
    /// **The block and not the whole view.** ``StateView`` fills a
    /// screen and puts the loud button in the thumb zone; here it is about **one**
    /// row among many, and the other shelves are fine. Only
    /// ``StateBlock`` is therefore drawn — the same sentence, the same symbol, no button that
    /// grabs the page for itself.
    ///
    /// **The names are below and not in the sentence.** The sentence is a language key
    /// and has no room for them; but a channel list is called what the viewer
    /// named it — and that is exactly the information that turns "something is missing" into
    /// "this list is missing".
    private func disruptedShelf(_ shelf: Shelf, _ disruption: ShelfDisruption) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: labeled(shelf.label))
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
                .padding(.horizontal, MetricsBoard.phone.margin)

            VStack(spacing: 6) {
                StateBlock(form: disruption.state.form)
                if !disruption.names.isEmpty {
                    Text(verbatim: disruption.names.joined(separator: DelimiterChars.point))
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, MetricsBoard.phone.margin)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, MetricsBoard.phone.section)
    }

    /// The row at the very bottom that leads into the register.
    ///
    /// **Without it the cap at four catalog shelves would be a silent omission.** Anyone who has
    /// six libraries and sees four shelves should not have to search for the rest —
    /// and the page ends with information instead of an edge.
    private var allCatalogs: some View {
        Button(action: tabPressed) {
            HStack {
                Text(app: "home.allStock")
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
                Spacer()
                Image(systemName: Glyph.next.name)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .frame(minHeight: Metrics.target)
        }
        .buttonStyle(.plain)
        .padding(.top, MetricsBoard.phone.section)
    }

    /// Open a tile — **with its origin, if Home knows one.**
    /// Continue Watching plays on tap — as on the TV (``Features/HomeModel``).
    private func playsOnTap(_ tile: TileContent, in shelf: Shelf) -> Bool {
        resume != nil && shelf.id == StartPreferences.immovable
            && tile.playsInHistory(origin: model.origin(zu: tile.id))
    }

    private func showDetails(_ tile: TileContent) {
        guard let toSeries else { return open(tile) }
        toSeries(tile, model.origin(zu: tile.id))
    }

    private func open(_ tile: TileContent) {
        open(tile, model.origin(zu: tile.id))
    }

    /// A key is translated, a wording stands as the server reports it.
    private func labeled(_ label: CaptionLabel) -> String {
        switch label {
        case .key(let name): AppLanguageSetting.text(.init(name))
        case .wording(let name): name
        }
    }
}
