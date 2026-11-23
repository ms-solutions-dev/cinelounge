import Core
import DesignSystemPhone
import Flows
import NetworkStatus
import PortalKit
import SwiftUI

/// Tab 4: the portals — **a tree, not a catalog.**
///
/// **The determination made here was withdrawn on 2026-09-06** (direction K3a). It
/// read: "Portal page and library are the same build with a different catalog … no
/// back arrow." That is true for a flat list and wrong for a tree — a
/// catalog gets **sorted**, a portal gets **walked through**.
///
/// Measured at the bridge: **four of eight** Serieshub entry points deliver pure
/// folder lists (30, 24, 18, 27 entries, not a single image). As a chip row above a
/// poster grid those were empty frames — and from a folder no way led back,
/// because there was no stack.
///
/// **The arrow now claims a stack because there is one.** On the root it does
/// not appear: there is nothing it would lead to.
///
/// **The portal choice still comes from below.** On the large title it would lie entirely above
/// the thumb limit.
public struct PortalsView: View {
    /// **Three columns on the phone, six on the iPad** — see ``MetricClass``.
    @Environment(\.horizontalSizeClass) private var widthClass

    @State private var model: PortalsModel
    @State private var isChoiceOpen = false
    @State private var searchTerm = ""
    /// How often it was refreshed by hand — only so that the haptics have a state.
    @State private var refreshCount = 0

    /// Shelf tiles, computed from the image width — see ``ShelfMetrics`` (AP4).
    @State private var shelfWidth = MetricsBoard.phone.poster.width
    @State private var wideShelfWidth = MetricsBoard.phone.episode.width

    /// Where the device currently is — see ``LocationMonitor``.
    ///
    /// **Default `unknown` and not `home`** (AP6): Until 2026-09-10. `.home` stood here
    /// hard-coded in the body. Whoever was out and about read a statement about their network
    /// that came from one line of code. With an unknown location no location line appears.
    var location: LocationStatement.Location = .unknown

    private let account: String
    private let onAccountTap: () -> Void
    /// The path to the favorites — **`nil` if they sit at the bottom of the bar.**
    ///
    /// With full setup the bar is full, and the favorites move to the
    /// top (``CatalogState/favoritesAtBottom``). Without this heart they would then be reachable from
    /// **nowhere** — the tab is missing precisely for that reason.
    private let onFavoritesTap: (() -> Void)?
    private let open: (TileContent) -> Void
    /// Continues playing a tile from "Continue Watching" — see ``TileContent/playsInHistory``.
    private let resume: ((TileContent) -> Void)?

    /// Who sets the seen mark and favorite — see ``TileCommands``.
    private let commandSource: (any DetailSource)?

    /// How a title stands in the downloads — `nil` where no downloads are kept.
    ///
    /// **Only for the switch at ``TileCommands/isDownloadable``**, nothing of it is drawn:
    /// on a title that is already stored there is no "Download".
    private let downloadState: ((String) -> DownloadState?)?

    /// Opens the download sheet for a tile — `nil` as long as nobody can pull it up.
    ///
    /// **The callback belongs to the wrapper**, because only it has a sheet state; the
    /// full reasoning is at ``TileCommands/load``. As long as it is `nil`, the long
    /// press here has three commands instead of four — and no dead one.
    private let load: ((TileContent) -> Void)?

    public init(
        source: (any PortalContentSource)?,
        account: String = "?",
        onAccountTap: @escaping () -> Void = {},
        onFavoritesTap: (() -> Void)? = nil,
        open: @escaping (TileContent) -> Void = { _ in },
        resume: ((TileContent) -> Void)? = nil,
        commandSource: (any DetailSource)? = nil,
        downloadState: ((String) -> DownloadState?)? = nil,
        load: ((TileContent) -> Void)? = nil,
        width: Int = 0,
        location: LocationStatement.Location = .unknown
    ) {
        self.location = location
        _model = State(
            initialValue: PortalsModel(
                source: source,
                preferences: { PortalPreferences.load(from: SecureStore()) },
                width: width))
        self.commandSource = commandSource
        self.downloadState = downloadState
        self.load = load
        self.account = account
        self.onAccountTap = onAccountTap
        self.onFavoritesTap = onFavoritesTap
        self.open = open
        self.resume = resume
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

                HStack(spacing: Metrics.targetSpacing) {
                    TitleChoice(title: model.chosen?.name ?? "") { isChoiceOpen = true }
                    // **The health state is shown on the page, not only in the sheet.**
                    // Readers break when a provider changes its layout; an empty
                    // result then reads as "app broken". A ready portal
                    // carries no mark — otherwise it would always be there and say nothing.
                    if let state = model.chosen?.state, state != .ready {
                        StateBadge(state: state)
                    }
                    Spacer(minLength: 0)
                }

                LocationRow(statement: LocationStatement.forItem(.portals, location: location))

                pathRow
                questionField
                // **Pulling refreshes this level and does not re-enter** (E40).
                // `load()` would start over at the portal's root; whoever pulls three
                // levels deep in a folder would end up at the top afterwards — and that is
                // worse than no gesture, because it looks like "refresh" and does
                // "start over".
                //
                // **On the shared host and not on each scroll area.** The portals
                // draw their content from two different areas; the gesture belongs
                // to the tab and not to one of them.
                content
                    .refreshable {
                        await model.refreshLevel()
                        refreshCount += 1
                    }
                    // **The haptics hang on the counter and not on the call** — the same
                    // build as in ``StartView``: `refreshable` brings none of its own,
                    // and a `Bool` did not report on the second pull.
                    .haptics(.succeeded, at: refreshCount)
            }
        }
        .task { await model.load() }
        // **Back also works with a swipe from the left edge** (AP7). On the ZStack and not on the
        // content: the portals draw from two scroll areas, and the gesture belongs to the
        // tab. ``EdgeSwipe`` runs as a `simultaneousGesture` — so it does not take the grip
        // away from the horizontally scrolling shelves.
        .edgeSwipe(backSwipe)
        .sheet(isPresented: $isChoiceOpen) { choiceSheet }
        // **On the whole screen and not per level.** The portals draw their shelves
        // from two different scroll areas; what is measured is the width that both share.
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { fresh in
            guard fresh > 0 else { return }
            shelfWidth = ShelfMetrics.tileWidth(at: fresh, sizeClass: widthClass)
            wideShelfWidth = ShelfMetrics.tileWidth(at: fresh, wide: true, sizeClass: widthClass)
        }
    }

    /// One level back — **the one place for arrow and swipe.**
    ///
    /// **The filter must come along.** The search word belongs to the level on which it was typed;
    /// if it stays when going back, the level below shows filtered without
    /// anyone having set a filter. With the arrow this always stood in the button body —
    /// when the gesture was added, a second body would have been exactly the duplication that
    /// makes one of the two forget.
    private func goBack() {
        model.back()
        searchTerm = ""
    }

    /// The backward gesture — or **none**, if there is nothing to go back to.
    ///
    /// ``EdgeSwipe`` takes `nil` for that, the same rule as for the downloads button in the
    /// ``HeaderRow``. The reasoning is that of the arrow, which does not appear on the root either:
    /// a way back that leads nowhere claims a place.
    private var backSwipe: (() -> Void)? {
        guard model.hasWayBack else { return nil }
        return goBack
    }

    private var choiceSheet: some View {
        ScrollView {
            PortalChoiceSheet(
                portals: model.portals, chosen: model.chosen?.id
            ) { portal in
                isChoiceOpen = false
                Task { await model.select(portal) }
            }
            .padding(.vertical, MetricsBoard.phone.gutter)
        }
        .presentationDetents([.fraction(SheetID.portalChoice.portion), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
        .presentationBackground(ColorRole.surfaceHigh.color)
    }

    /// Where one stands — and the way back.
    ///
    /// **On the root there is no arrow.** A way back that leads nowhere claims
    /// a place; that was exactly the reasoning with which the old version had none at all.
    @ViewBuilder
    private var pathRow: some View {
        if model.hasWayBack, let pending = model.pending {
            HStack(spacing: Metrics.targetSpacing) {
                Button {
                    goBack()
                } label: {
                    Image(systemName: Glyph.back.name)
                        .foregroundStyle(ColorRole.textMatt.color)
                }
                .target()
                .accessibilityLabel(Text(app: "common.back"))

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: pending.title)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                        .lineLimit(1)
                    // **The whole path as a quiet line.** With three levels the title
                    // alone no longer says where one is — "Action" exists under "Series"
                    // and under "Films".
                    Text(verbatim: model.path)
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.bottom, Metrics.targetSpacing)
            .accessibilityElement(children: .combine)
        }
    }

    /// The input field of a level that asks a **question**.
    ///
    /// The entry point "Search" answers with `braucht_eingabe` and until 2026-09-06 landed in the
    /// empty state "Nothing here" — a screen that asks a question and has no
    /// place to answer it.
    ///
    /// **The suggestion stands in the field as soon as the level changes** — and only then. It is
    /// what the reader's keyboard would have been prefilled with (``PortalLayer/suggestion``);
    /// writing it in again on every redraw would take the letter away from under the
    /// viewer's thumb.
    @ViewBuilder
    private var questionField: some View {
        if let query = model.pending?.query {
            VStack(alignment: .leading, spacing: 4) {
                SearchField(text: $searchTerm, placeholder: "portal.search.placeholder")
                Text(verbatim: query)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.bottom, Metrics.targetSpacing)
            .onSubmit { Task { await model.answer(searchTerm) } }
            .task(id: model.pending?.identifier) {
                searchTerm = model.pending?.suggestion ?? ""
            }
        }
    }

    /// A level of folders — **rows and not empty frames.**
    ///
    /// The level decides the form and not the tile; the rule is at
    /// ``PortalLayer/areFolders``, and it stands there in this direction because the other one
    /// was wrong once before.
    private func folderList(_ level: PortalLayer) -> some View {
        ScrollSurface(location: scrollAnchor(level)) {
            LazyVStack(alignment: .leading, spacing: 0) {
                folderColumn(level)
            }
            // **So that the remembered position is a row and not an offset.** Only with
            // this marker does
            // ``SwiftUI/View/onScrollTargetVisibilityChange(idType:threshold:_:)`` report the
            // identifier of the topmost visible row; an offset alone could not be restored on
            // an area that does not exist yet. Snapping is therefore **not** done — that would need a
            // `scrollTargetBehavior`, and that is deliberately absent
            // here.
            .scrollTargetLayout()
            // The same column as in the branch with its own area — see there.
            .contentColumn(widthClass)
            .padding(.top, Metrics.targetSpacing)
        }
    }

    /// The handle on the remembered scroll position of **this** level.
    ///
    /// **On the model and not on the view** — the reasoning is at
    /// ``PortalsModel/scrollAnchor(forItem:)``: this very view is torn down when one goes
    /// one level deeper.
    ///
    /// **Optional in and optional out** (2026-09-09): The grid branch also stands where
    /// there is no open level at all — then there is nothing to remember, and `nil` is
    /// the right answer. An invented identifier would be a compartment that nobody ever reads.
    ///
    /// **A string and not a `ScrollPosition`** — the correction of 2026-09-09 in the
    /// afternoon. What the binding carries is the identifier of the topmost visible row;
    /// why the first version **could** not hold is at ``ScrollSurface/location``.
    private func scrollAnchor(_ level: PortalLayer?) -> Binding<String?>? {
        guard let identifier = level?.identifier else { return nil }
        return Binding(
            get: { model.scrollAnchor(forItem: identifier) },
            set: { model.memorize(scrollAnchor: $0, forItem: identifier) })
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .isLoading:
            LoadingState(message: "portal.loading").frame(maxHeight: .infinity)

        case .disrupted(let state):
            StateView(state: state, action: { Task { await model.load() } })

        case .locked(let state):
            locked(state)

        case .empty:
            // **A follow-up question is not an empty report.** Only after it the empty state: the
            // level is empty only if nobody is waiting for an answer any more.
            if let followUpQuestion = model.pending?.followUpQuestion {
                followUpBlock(followUpQuestion)
            } else if model.pending?.query != nil {
                unanswered
            } else {
                // **The bridge's literal notice, if it has one.** An empty
                // level is not an error: a performer without videos, a page beyond
                // the last. If a text stands there, it is the information.
                emptyBlock
            }

        case .settled:
            if model.pending?.query != nil {
                unanswered
            } else if let level = model.pending, level.areFolders {
                if model.showsOwnArea {
                    // **The own area stands above the menu and scrolls with it.** Two
                    // separate scroll areas on top of each other would be two screens in one;
                    // the same rule as on the Home screen, where header box and shelves are one
                    // area.
                    ScrollSurface(location: scrollAnchor(level)) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ownSection
                            folderColumn(level)
                        }
                        .scrollTargetLayout()
                        // **A folder list is text and needs no 1032 points**
                        // (AP7, 2026-09-23). On the iPad the word stood at the left and its arrow at the
                        // far right, in between roughly 1900 pixels of nothing — two
                        // pieces of information that belong together, at opposite ends.
                        // The same answer as in Settings, and that is deliberate:
                        // solving two lists with the same flaw differently would be
                        // exactly the duplication this project otherwise avoids.
                        .contentColumn(widthClass)
                        .padding(.top, Metrics.targetSpacing)
                    }
                } else {
                    folderList(level)
                }
            } else {
                VStack(spacing: 0) {
                    sortRow
                    // **The grid also remembers its position** (2026-09-09): The reported case
                    // was the folder list, but the way back from a mixed level
                    // is the same branch switch and would lose it just the same. Two branches that
                    // remember differently would be a difference that nobody
                    // can explain.
                    TitleGrid(
                        order: model.order, open: openTile,
                        atEnd: { Task { await model.loadMore() } },
                        // **The long press, added on 2026-09-09** Finding on the device:
                        // in portals long-pressing does not yet work for choosing favorite etc.
                        // directly … in the library it works. The finding
                        // was right, and the cause lay exactly here: ``TitleGrid``
                        // attaches its menu only if ``TitleGrid/commandSource`` or
                        // ``TitleGrid/load`` is set (see the reasoning there —
                        // a menu with ineffective commands would be worse than none),
                        // and this call set neither. The shelf branch above it
                        // brought its commands along itself; that is why it worked in the own
                        // area and not in the grid.
                        //
                        // **Why it is exactly this branch, measured again at the bridge:**
                        // `flatone › Clips` delivers 24 films and 3 folders —
                        // ``PortalLayer/areFolders`` is thus false, and the level becomes
                        // a grid.
                        commandSource: commandSource,
                        downloadState: downloadState, load: load,
                        location: scrollAnchor(model.pending),
                        // **After a command the own area refreshes.** A
                        // favorite set in the grid stands in the shelf above — and without this line
                        // it would show up there only at the next portal switch.
                        following: { Task { await model.refreshOwnArea() } })
                    loadMoreRow
                }
            }
        }
    }

    /// "Continue Watching" and "Favorites" **of this one portal.**
    ///
    /// **They appear only if the portal has its own area** — the switch is in
    /// `Settings → Portals`, the rule at ``PortalPreferences``. If it counts in
    /// the shared shelves, the same stands on the Home screen and in the
    /// Favorites tab; both at once would be the same information in two places.
    ///
    /// **The same row as on the Home screen** (``ShelfRow``), and not a second
    /// build: whoever comes from there should find the same grammar.
    @ViewBuilder
    private var ownSection: some View {
        shelfRow("portal.continue", model.ownHistory, inHistory: true)
        shelfRow("tab.favorites", model.ownFavorites, inHistory: false)
    }

    @ViewBuilder
    private func shelfRow(
        _ title: String, _ tiles: [TileContent], inHistory: Bool
    )
        -> some View
    {
        if !tiles.isEmpty {
            let wide = TileContent.isWideShelf(tiles)
            ShelfRow(
                title: SettingsModel.text(title), tally: "\(tiles.count)"
            ) {
                ForEach(tiles) { tile in
                    let isPlaying =
                        inHistory && resume != nil && tile.playsInHistory(origin: .portals)
                    Button {
                        if isPlaying { resume?(tile) } else { openTile(tile) }
                    } label: {
                        PosterTile(
                            content: tile,
                            width: wide ? wideShelfWidth : shelfWidth,
                            wideFrame: wide)
                    }
                    .buttonStyle(.plain)
                    .tileCommands(
                        tile, origin: .portals, source: commandSource,
                        inHistory: inHistory,
                        details: isPlaying ? { openTile(tile) } : nil,
                        following: { Task { await model.refreshOwnArea() } })
                }
            }
            .padding(.bottom, MetricsBoard.phone.section)
        }
    }

    /// The folder rows **without** a scroll area of their own — for the case that something stands above.
    ///
    /// **One list and two wrappers, not two lists.** Without this split the same body
    /// would stand there twice, and the second would stay when the first changes.
    ///
    /// **And explicitly no long press here** (checked on 2026-09-09, together with
    /// the addendum on the grid). ``TileCommands`` offers four things: seen mark,
    /// favorite, download, reset progress. A folder has **none of them** —
    /// it is a door and not a title: there is nothing to see, nothing to remember, nothing to
    /// fetch and no progress. The three commands would call ``DetailSource`` with a
    /// level identifier, and the bridge knows no mark for a level; the menu
    /// would open and do nothing — exactly the case that ``TitleGrid/commandSource`` rules out as
    /// "worse than none".
    ///
    /// **A folder *in the grid* is not affected**, and that is no contradiction:
    /// there it stands among titles, the menu belongs to the level and not to the tile, and the
    /// three folders among the 24 films of `flatone › Clips` are the price
    /// for the 24 getting their menu.
    @ViewBuilder
    private func folderColumn(_ level: PortalLayer) -> some View {
        let recent = model.recentlyUsed
        ForEach(level.entries) { entry in
            if entry.isSeparator {
                if let key = PortalGroups.wordingKey(for: entry.title) {
                    SectionHeader(title: key)
                } else {
                    SectionHeader(wording: entry.title)
                }
            } else {
                FolderRow(entry: entry, isLoading: model.opens == entry.id) {
                    Task { await model.open(entry) }
                }
                // **The identifier makes the row jumpable.** Without it the
                // remembered scroll position would have nothing to hold on to when coming back —
                // the same role as the `.id(…)` on the tiles of the
                // ``TitleGrid``, which serves the jump bar there.
                .id(entry.id)
                // **The one exception to "a folder has no menu"** (2026-10-12): Under
                // "Recently Used" the long press takes the page out of the group.
                .contextMenu {
                    if recent.contains(entry.id) {
                        Button(role: .destructive) {
                            Task { await model.forgetRecent(entry) }
                        } label: {
                            Label(app: "portal.forgetRecent", systemImage: Glyph.remove.name)
                        }
                    }
                }
                .onAppear {
                    // Since AP76 on the last twelve instead of the last one — ``Flows/LoadMore``.
                    if LoadMore.applies(entry, in: level.entries) {
                        Task { await model.loadMore() }
                    }
                }
            }
        }
        loadMoreRow
    }

    /// Title and rating — **sorted by the CL-Server across all pages** (AP60).
    ///
    /// The same button row as in the library. Below it, while the server collects the level
    /// for the first time, how far it is: with 900 entries that takes minutes,
    /// and a list that does not move after the press would look like a dead button.
    private var sortRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SortRow(choice: model.choice, possible: model.availableOrders) { tapped in
                Task { await model.tap(tapped) }
            }
            if let done = model.preparedCount {
                HStack(spacing: 8) {
                    ProgressView().tint(ColorRole.textMatt.color)
                    Text(verbatim: AppLanguageSetting.text("portal.sortingPrepared \(done)"))
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.vertical, MetricsBoard.phone.gutter / 2)
    }

    /// What stands at the end of a list that is not finished yet.
    ///
    /// **A spinner below the list and not a loading screen above it.** What is already there
    /// stays visible and usable; whoever got a full loading view while paging
    /// would lose the place they were just at.
    ///
    /// **The count line appears only where the portal names a number.** Animehub and
    /// Serieshub name it for "All series", the ARD for no entry point — and there
    /// "15 of 15" would be an assertion about something nobody knows.
    @ViewBuilder
    private var loadMoreRow: some View {
        if let level = model.pending {
            VStack(spacing: 4) {
                if model.isLoadingMore {
                    ProgressView().tint(ColorRole.textMatt.color)
                }
                if let total = level.total, total > level.entries.count {
                    Text(
                        verbatim: AppLanguageSetting.text("portal.count \(level.entries.count) \(total)")
                    )
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                }
                if level.truncated {
                    Text(appKey: "portal.truncated")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, level.hasMore || level.total != nil ? MetricsBoard.phone.gutter : 0)
        }
    }

    /// The portal is there and not usable — **with the task that goes with it.**
    ///
    /// Two cases, two tasks, and both name the task and not the mechanism: the
    /// viewer should know **what to do**, not what it is called.
    @ViewBuilder
    private func locked(_ state: PortalState) -> some View {
        switch state {
        case .login:
            StateBlock(
                form: .job(
                    Job(
                        icon: Glyph.login.name,
                        headline: "portal.login.title", message: "portal.login.text",
                        button: "common.signIn", target: .portalSettings))
            )
            .frame(maxHeight: .infinity)
        case .needsSetting:
            StateBlock(
                form: .job(
                    Job(
                        icon: Glyph.settings.name,
                        headline: "portal.setting.title", message: "portal.setting.text",
                        button: "portal.setting.button", target: .portalSettings))
            )
            .frame(maxHeight: .infinity)
        default:
            VStack(spacing: 10) {
                StateBlock(
                    form: .info(
                        StateInfo(
                            icon: Glyph.offline.name,
                            headline: "portal.silent.title", message: "portal.silent.text")))
                // **The bridge's base text verbatim.** "Does not work" is no information,
                // the service's own reason is — and a sentence produced by a portal we
                // do not know could not be translated anyway.
                if let wording = state.wording {
                    Text(verbatim: wording)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, MetricsBoard.phone.margin)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Press a tile — **one level deeper or onto the detail page.**
    ///
    /// A folder **in** the grid is not a special case: A mixed level becomes a grid,
    /// and a folder in it is a tile like any other. Where it leads is decided by
    /// the entry and not this place.
    private func openTile(_ tile: TileContent) {
        guard let entry = model.pending?.entries.first(where: { $0.id == tile.id })
        else { return }
        if entry.leadsDeeper != nil {
            Task { await model.open(entry) }
        } else {
            open(tile)
        }
    }

    /// A level that **asks** — and whose list belongs to somebody else.
    ///
    /// **Finding of 2026-09-09:** tapping "New Search" should open a search window,
    /// but the following opens instead — and below it a grid of foreign hits.
    ///
    /// **Measured again at the bridge, twice in one afternoon:**
    /// `flatone › Clips › Search › New Search` answers with
    /// `braucht_eingabe: "Enter search text for clips"` **and** thirteen entries.
    /// On the first request `eingabe_vorschlag` read `"redhead"`, on the second `"sunset"` —
    /// and on the second all thirteen titles carried the word "Sunset". That proves
    /// whose hits these are: **those of the last search in the reader**, not those of a
    /// viewer of this app. They change whenever anybody searches anywhere else.
    ///
    /// **That is why the list is not drawn as long as the question is open.** Thirteen
    /// foreign hits below a field that is just asking for input are an
    /// answer to a question nobody asked — and they look like the
    /// result of the press that just happened.
    ///
    /// **Empty and without an announcement of its own.** What is to be done here already stands two lines
    /// higher: the search field and below it the portal's question sentence in
    /// its wording (``questionField``). A state block next to it would be the same information a second time —
    /// and a search screen before the first input **is** empty; that is not
    /// a gap, but the right information.
    ///
    /// **As soon as it is submitted, the list returns.** ``PortalsModel/answer(_:)``
    /// creates the answer as a level of its own, and that one no longer carries a question.
    private var unanswered: some View {
        Spacer(minLength: 0)
    }

    /// An empty level is not an error.
    ///
    /// A performer without videos, a page beyond the last. **If a notice
    /// from the bridge is there, it is the information** — until 2026-08-28 it threw an error for this,
    /// and on the device "liste: RuntimeError" stood, red, like a defect.
    /// The portal has **asked** and is waiting for a yes.
    ///
    /// **Finding of 2026-09-09:** "Clear Search History" delivers an empty level with the sentence
    /// "Confirm: Are you sure you want to clear the search history?" — and the view
    /// wrote "Nothing here" over it. That is the wrong information about the wrong
    /// matter: the level is not empty, it is unanswered.
    ///
    /// **There is no yes button here yet**, and it says so. The way back is missing
    /// at the bridge: a "yes" would need a parameter that reaches all the way into
    /// `Portal.list` like `input`. Showing a button that confirms nothing would be the second
    /// false statement after the first.
    private func followUpBlock(_ wording: String) -> some View {
        VStack(spacing: 10) {
            StateBlock(
                form: .info(
                    StateInfo(
                        icon: Glyph.check.name,
                        headline: "portal.confirm.title", message: "portal.confirm.text")))
            // **The portal's wording, untranslated.** What a foreign reader asks,
            // nobody here knows — and an invented translation would turn its question
            // into a different one.
            Text(verbatim: wording)
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MetricsBoard.phone.margin)
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyBlock: some View {
        VStack(spacing: 10) {
            StateBlock(
                form: .info(
                    StateInfo(
                        icon: Glyph.emptyCatalog.name,
                        headline: "portal.empty.title", message: "portal.empty.text")))
            if let hint = model.pending?.hint {
                Text(verbatim: hint)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, MetricsBoard.phone.margin)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
