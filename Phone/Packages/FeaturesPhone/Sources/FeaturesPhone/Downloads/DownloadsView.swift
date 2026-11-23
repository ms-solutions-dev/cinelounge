import DesignSystemPhone
import Downloads
import SwiftUI

/// Downloads: **three versions.**
///
/// Full, empty, offline. The empty downloads screen is a piece of information with a quiet
/// path into the library — not an error and not an ad; you see the difference from "Login
/// expired" **before** you read.
///
/// **The offline version is the market gap in one screen.** Plex lets the library spin
/// endlessly in airplane mode, and the ARD Mediathek requires an internet connection to play
/// downloaded videos — both **have** downloads. Here the list appears immediately, nothing is
/// fetched and nothing is queried, and what does not work is **named** instead of silently
/// left out.
///
/// **The header looks like the library's** (usability finding 13): title with a selection
/// indicator, **no back arrow**, profile picture and search field in the same places. An
/// arrow claims a stack and therefore a different place — but downloads are the same place
/// with a different catalog.
public struct DownloadsView: View {
    /// **Three columns on the phone, six on the iPad** — see ``MetricClass``.
    @Environment(\.horizontalSizeClass) private var widthClass

    @State private var model: DownloadsModel
    /// Which row currently has its swipe open — **one for the whole list.** Two open rows on top
    /// of each other can no longer be closed with one thumb.
    @State private var openSwipe: String?

    /// Which confirmation prompt is currently open — `nil` means none.
    ///
    /// **Bulk removal asks, a single swipe does not.** The difference is the amount: a swipe hits
    /// the row under the thumb and can still be cancelled on release; a bulk button takes fourteen
    /// gigabytes at once, and part of what it hits is off screen. This is the rule from
    /// ``Downloads/Cleanup``: deleting asks.
    @State private var followUpQuestion: Confirmation?

    /// **A poster hides how much stands behind it — hence a third case.**
    ///
    /// As long as the list consisted of rows, a command hit exactly the row under the thumb, and
    /// the rule "removing a single item does not ask" held. A poster can stand for eight episodes;
    /// "Remove" on it is a bulk command, even if it looks like a single one. That is exactly what
    /// the confirmation prompt from ``Downloads/Cleanup`` is for — it names count and amount
    /// before anything goes away.
    private enum Confirmation: Identifiable {
        case selected, watchedJobs
        case group(DownloadGroup)

        var id: String {
            switch self {
            case .selected: "selected"
            case .watchedJobs: "watched"
            case .group(let group): "group:" + group.id
            }
        }
    }

    /// How wide a poster is — **measured, not assumed.**
    ///
    /// The same line as in ``FavoritesScreen``: ``TitleGrid/tileWidth(at:wide:)`` computes
    /// from the scroll view width so that the same title is shown at the same size in downloads as
    /// in the library. A fixed number would be either too narrow or too wide on every other
    /// device, and you see both immediately.
    @State private var tileWidth = MetricsBoard.phone.poster.width

    /// Who is watching right now — for the profile picture in the header.
    private let account: String
    private let onAccountTap: () -> Void

    /// The catalog choice behind the title — **`nil` where there is nothing to choose.**
    ///
    /// Offline, the registry leads to libraries that do not answer; then the title carries no
    /// selection indicator. The same indicator for two meanings — "there is a choice here" and
    /// "there used to be one here" — would be worse than none.
    private let tabPressed: (() -> Void)?

    /// The ways out — handed in by the view so that this package does not know the shell.
    private let storage: () -> Void
    private let toLibrary: () -> Void
    private let network: () -> Void
    /// Whether the banner already sits above this screen.
    ///
    /// **Finding from 2026-09-08, in the simulator:** With the bar gone, "No network — your downloads
    /// are here" stood in the banner **and** "Offline — and this still works" one line below.
    /// The same information twice on one screen is once too often, and the upper one is the one
    /// you read first.
    ///
    /// **Only the repetition is removed, not the explanatory sentence.** "What does not work
    /// offline" says something different — namely what is missing — and stays in both versions.
    private let isBandOnTop: Bool

    /// Delete from downloads — **the only action here that takes something away.**
    private let remove: (DownloadJob.Identifier) -> Void
    /// Pause or resume, depending on what is currently running.
    private let control: (DownloadJob.Identifier) -> Void

    /// The tap on the row — **and it deletes nothing.**
    ///
    /// **Finding from 2026-09-09:** tapping a row made the download seem to vanish. It
    /// did not disappear, it was **removed**: the main button of the ``DownloadRow`` was wired to
    /// `remove`. A tap without a confirmation prompt that throws away a finished 466 MB download
    /// is the most expensive mistake this screen can offer — and it looked like "open".
    ///
    /// **Removing stays reachable, but only deliberately:** via the long press and via "Select"
    /// with a confirmation prompt. That is the same rule as everywhere here — one gesture, one
    /// meaning.
    private let open: (DownloadJob) -> Void

    /// The tap on a **series poster** — `nil` as long as nobody answers it.
    ///
    /// **"Poster → detail view with downloaded episodes" (product requirement, 2026-09-09) means, for
    /// a group: the series and not the first episode.** ``open`` hands out a
    /// ``Downloads/DownloadJob``, and for a series that is always a single episode — whose detail
    /// page has neither a season picker nor an episode list. What is needed is the identifier from
    /// ``Downloads/DownloadDescription/series``, and that is not a job identifier; pushing it through
    /// ``open`` would mean inventing a download job that does not exist.
    ///
    /// **What is handed out is the key and not a finished identifier.** What becomes of it is
    /// known to ``DownloadsDetailSource/identifier(forItem:)`` — it expects exactly that: "the series
    /// identifier for a series, otherwise the identifier of the download job". This view does not
    /// set the prefix itself; if it did, there would be two places that know what a downloads
    /// identifier looks like, and the second would be wrong after the next refactoring.
    ///
    /// **`nil` is the valid transitional state and not a gap.** Without this callback the poster
    /// leads to the first episode — that is, to where it led before 2026-09-09. That is worse than the
    /// series and better than nothing; which line is missing on the outside is stated in the
    /// report for this package.
    private let openSeries: ((String) -> Void)?

    /// The way back — **`nil` wherever there is none.**
    ///
    /// **Downloads carry no back arrow** (usability finding 13: "An arrow claims a stack and
    /// therefore a different place"), and that still holds: in the tab and offline, downloads are
    /// the same place with a different catalog, and then `nil` stands here.
    ///
    /// **It is set exactly once** — in the ``DownloadsDrawer`` that lies over the Home screen.
    /// There is a place you came from, and it is named ("Home") instead of being claimed with a
    /// bare arrow. Without it the swipe at the left edge would be the only way out — a gesture you
    /// cannot see does not exist for someone who does not know it.
    private let back: (wohin: String, action: () -> Void)?

    public init(
        model: DownloadsModel,
        account: String = "?",
        onAccountTap: @escaping () -> Void = {},
        tabPressed: (() -> Void)? = nil,
        isBandOnTop: Bool = false,
        back: (wohin: String, action: () -> Void)? = nil,
        storage: @escaping () -> Void = {},
        toLibrary: @escaping () -> Void = {},
        network: @escaping () -> Void = {},
        remove: @escaping (DownloadJob.Identifier) -> Void = { _ in },
        control: @escaping (DownloadJob.Identifier) -> Void = { _ in },
        open: @escaping (DownloadJob) -> Void = { _ in },
        openSeries: ((String) -> Void)? = nil
    ) {
        _model = State(wrappedValue: model)
        self.account = account
        self.onAccountTap = onAccountTap
        self.tabPressed = tabPressed
        self.isBandOnTop = isBandOnTop
        self.back = back
        self.storage = storage
        self.toLibrary = toLibrary
        self.network = network
        self.remove = remove
        self.control = control
        self.open = open
        self.openSeries = openSeries
    }

    public var body: some View {
        ScrollSurface {
            VStack(alignment: .leading, spacing: 0) {
                header

                switch model.version {
                case .full: filled
                case .empty: empty
                case .offline: offline
                }
            }
        }
        // **Measured once, not per section** — the same line as in ``FavoritesScreen``. A
        // `GeometryReader` around the grid would not work here: in a `VStack` inside a scroll view
        // it proposes no height and would collapse to zero.
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { fresh in
            guard fresh > 0 else { return }
            tileWidth = TitleGrid.tileWidth(at: fresh, sizeClass: widthClass)
        }
        // **The bar is inserted and does not sit on top.** An `overlay` would put it over the last
        // row, and that row could then no longer be checked — of all rows, the one you scrolled to.
        .safeAreaInset(edge: .bottom) { bulkBar }
        // **On appearing and not on building.** Anyone who views a downloaded episode in between and
        // comes back wants to find it under "Watched" — and the next one should already be queued.
        // Both depend on the **watch state** and not on the download state; a trigger at the end of a
        // transfer would miss exactly the case it exists for.
        .task {
            // **And the descriptions with it** (2026-09-09): They are what turns a row into a poster. Anyone
            // who queues an episode and comes back wants to find it under its series image — a state from
            // when the model was created would be empty.
            model.readDescriptions()
            await model.readWatched()
            await model.queueNewEpisodes()
        }
        .confirmationDialog(
            Text(app: "stock.remove"), isPresented: asks, titleVisibility: .visible,
            presenting: followUpQuestion
        ) { which in
            Button(role: .destructive) {
                removeAll(affected(which))
            } label: {
                Text(verbatim: message(forItem: which))
            }
        }
    }

    /// What the confirmation prompt would take with it.
    private func affected(_ which: Confirmation) -> [DownloadJob.Identifier] {
        switch which {
        case .selected: selected
        case .watchedJobs: model.watchedJobs.map(\.id)
        case .group(let group): group.identifiers
        }
    }

    /// What the red button says — **count and amount, never just "Remove".**
    private func message(forItem which: Confirmation) -> String {
        switch which {
        case .selected: model.bulkText ?? ""
        case .watchedJobs: model.watchedText ?? ""
        case .group(let group): model.groupText(group)
        }
    }

    /// Whether a confirmation prompt is open at all — the `Binding` for the dialog.
    private var asks: Binding<Bool> {
        Binding(get: { followUpQuestion != nil }, set: { if !$0 { followUpQuestion = nil } })
    }

    private var selected: [DownloadJob.Identifier] {
        model.visible.map(\.id).filter { model.selection.contains($0) }
    }

    /// **Collecting is repeated single removal and not a second path.** ``remove`` takes the
    /// file along, strikes the entry and writes the ledger — a second version of that would be the
    /// place where one of those gets forgotten.
    private func removeAll(_ identifiers: [DownloadJob.Identifier]) {
        for identifier in identifiers { remove(identifier) }
        model.selection.close()
    }

    // MARK: - Kopf

    /// **The same header as in the library** — usability finding 13.
    ///
    /// Profile picture top right, below it the title with the selection indicator, below that the
    /// search field: the same three things in the same three places. **No back arrow** — an arrow
    /// claims a stack and therefore a different place; downloads are the same place with a
    /// different catalog.
    ///
    /// **Offline, the profile picture is more than decoration.** Then there is no tab bar any
    /// more, and this circle is the only way into the person sheet and settings — the screen would
    /// otherwise be a dead end.
    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.targetSpacing) {
            HeaderRow(
                account: account, onAccountTap: onAccountTap,
                onNetworkTap: network)

            // **Above the title and not beside it** — the same construction as in ``SheetFrame``: first
            // the way back with the name of its destination, then the name of this place. Side by side
            // they would be two titles, and the upper one would win.
            if let back {
                Button(action: back.action) {
                    HStack(spacing: 4) {
                        Image(systemName: Glyph.back.name)
                            .iconSize(13, weight: .semibold)
                        Text(verbatim: back.wohin)
                            .font(TypeLevel.footer.font)
                            .lineLimit(1)
                    }
                    .foregroundStyle(ColorRole.brandLight.color)
                    .frame(minHeight: Metrics.target, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, MetricsBoard.phone.margin)
            }

            HStack(alignment: .firstTextBaseline) {
                if let tabPressed {
                    TitleChoice(title: CaptionLabel.key("stock.title").readable) {
                        tabPressed()
                    }
                } else {
                    LargeTitle(title: "stock.title")
                        .padding(.horizontal, MetricsBoard.phone.margin)
                }

                Spacer(minLength: Metrics.targetSpacing)

                // **"Select" stands in the header and not behind a ⋯.** A feature in the overflow menu does
                // not exist for most users — the same finding that moved the downloads button to the detail
                // page (usability 12).
                if model.version == .full {
                    Button {
                        if model.selection.pending {
                            model.selection.close()
                        } else {
                            model.selection.open()
                            openSwipe = nil
                        }
                    } label: {
                        Text(app: model.selection.pending ? "common.done" : "common.select")
                            .font(TypeLevel.footer.font)
                            .foregroundStyle(ColorRole.brandLight.color)
                            .frame(minHeight: Metrics.target)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, MetricsBoard.phone.margin)
                }
            }

            // **The search field is there even offline, and that is the point.** It searches what lies
            // here — no fetch, no wait, no error case. A search across all catalogs could not do that and
            // would stand here as a lie.
            SearchField(text: $model.search, placeholder: "stock.searchPlaceholder")
                .padding(.horizontal, MetricsBoard.phone.margin)
        }
        .padding(.bottom, Metrics.targetSpacing)
    }

    // MARK: - Filled

    @ViewBuilder
    private var filled: some View {
        storageRow

        // **Until 2026-09-09 this held "Download several" with the airplane symbol** and led to the sheet
        // "For the trip" (choose a duration, get a suggestion, read the completion time). The product
        // owner removed it: only the downloads view is needed, so the airplane button goes too. Button and sheet were **one** feature, not
        // two — that is why both went together.

        filter

        if !model.selection.pending, let message = model.watchedText {
            // **The one cleanup path that needs no selection.** "What I have already watched" is the
            // question you ask before the flight home, and it has exactly one answer — having to check
            // seven rows first is work without a decision.
            Button {
                followUpQuestion = .watchedJobs
            } label: {
                HStack(spacing: Metrics.targetSpacing) {
                    Image(systemName: Glyph.remove.name)
                    Text(verbatim: message)
                    Spacer(minLength: 0)
                }
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.brandLight.color)
                .frame(minHeight: Metrics.target)
                .padding(.horizontal, MetricsBoard.phone.margin)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        if model.selection.pending {
            selectionList
        } else {
            nowPlaying(model.filter)
            finishedItems(model.filter)
        }
    }

    /// During selection it stays with **rows** — and that is not a half measure.
    ///
    /// **What is checked is the file and not the series.** A poster stands for five episodes; a
    /// check mark on it cannot say "three of them". Letting posters be checked here would offer
    /// either everything or nothing — and "everything" is exactly the grab that takes fourteen
    /// gigabytes at once without you seeing what is in it. The bulk selection therefore keeps
    /// working on ``Downloads/DownloadJob/id``, as ``Downloads/BulkSelection`` carries it, and the row is
    /// the form in which an episode shows its name and its size.
    ///
    /// **There is no context menu during selection.** A command and a check mark on the same row
    /// are two ways to take the same thing away, and they contradict each other on the decisive
    /// point: one does not ask, the other does.
    @ViewBuilder
    private var selectionList: some View {
        ForEach(model.rows(forItem: model.filter)) { job in
            DownloadRow(
                job: job,
                transfer: model.downloads.isRunning.first { $0.id == job.id },
                isChecked: model.selection.contains(job.id),
                menu: { model.selection.toggle(job.id) },
                control: {})
            Separator(isIndented: true)
        }
    }

    /// **What is still loading keeps its row** — with megabytes, completion time and button.
    ///
    /// **A poster with a progress bar says less than "218.1 MB / 465.6 MB · done around 17:25".**
    /// The bar answers "how far", not "what is happening" — and all three known failures of the
    /// competition are transport failures in which a bar stands still and says nothing else (see
    /// ``DownloadRow``). As long as something is in transit, this information is the more
    /// important; once it is here, it is the picture.
    ///
    /// **And that is why two sections instead of one mixed form.** A row between posters has no
    /// column, a poster between rows has no line. The cut runs where it runs anyway: in transit or
    /// here.
    @ViewBuilder
    private func nowPlaying(_ filter: DownloadsModel.Filter) -> some View {
        let running = model.running(forItem: filter)
        // **The header appears only when something is really flowing.** ``DownloadsModel/downloadLine``
        // counts exactly that; a paused and a waiting download job are two other states with two
        // sentences of their own, and those stand at their row. "Loading now" over a stack of paused
        // downloads — the normal case in airplane mode — would be the only line on this screen that
        // claims something false. The rows can still be told apart from the posters: below them it
        // says "Available here".
        if let downloadLine = model.downloadLine, !running.isEmpty {
            // The section header names the group, the number beside it says how much is still
            // outstanding — "2 · 3.1 GB left". Composed, hence a wording.
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "stock.loadingNow")
                Spacer(minLength: Metrics.targetSpacing)
                Text(verbatim: downloadLine)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .padding(.trailing, MetricsBoard.phone.margin)
            }
        }

        ForEach(running) { job in
            // **``SwipeCommands`` without a drag** — the long press stays, the swipe goes.
            //
            // **The finding from 2026-09-09:** swiping from Home opened downloads, but swiping the other way
            // did not close them again. These rows carried their drag as a `highPriorityGesture`
            // from twenty points, and thereby covered the strip where the ``DownloadsDrawer`` had hung
            // its own gesture. Two meanings for one movement, and the prioritized one won — the screen
            // could no longer be pushed shut.
            //
            // **The product owner decided (2026-09-09): the drawer wins.** The price is paid deliberately —
            // this row loses its delete swipe. Removing remains under the **long press** (the context menu
            // draws ``SwipeCommands`` unchanged) and via "Select" at the top right; for the screen reader
            // it is available as an action on the row anyway, and for it a swipe was never a path — it
            // occupies the gesture itself.
            //
            // **That is why the building block stays and is not replaced.** Buttons, context menu and
            // screen reader get their commands from **one** list there; a second, swipe-free construction
            // next to it would have them twice, and the next command would be missing from one of the two.
            SwipeCommands(
                pending: $openSwipe, identifier: job.id.rawValue,
                commands: [
                    SwipeCommand(
                        id: "remove", title: "stock.remove",
                        icon: Glyph.remove.name, kind: .route,
                        action: { remove(job.id) })
                ],
                movesAccount: false
            ) {
                DownloadRow(
                    job: job,
                    transfer: model.downloads.isRunning.first { $0.id == job.id },
                    menu: { open(job) },
                    control: { control(job.id) })
            }
            Separator(isIndented: true)
        }
    }

    /// What is finished here — **as posters.**
    @ViewBuilder
    private func finishedItems(_ filter: DownloadsModel.Filter) -> some View {
        let groups = model.finishedGroups(forItem: filter)
        if !groups.isEmpty {
            // **The header appears only where something already stands above it.** An "Available here"
            // over a screen on which nothing else lies names the obvious and costs a line that the grid
            // lacks.
            if !model.running(forItem: filter).isEmpty {
                SectionHeader(title: "stock.done")
            }
            posterGrid(groups)
        }
    }

    /// The grid of posters.
    ///
    /// **Why not ``TitleGrid`` itself, although it draws exactly this grid.** It brings its
    /// **own** ``ScrollSurface`` and a `GeometryReader` with `maxHeight: .infinity` — it is a whole
    /// screen and not a section. Downloads are a single scroll view in which header, storage line,
    /// filters and the running downloads stand above the grid; a scroll view in a scroll view
    /// scrolls either not at all or at the wrong place. The same decision was made on 2026-09-07 in
    /// ``FavoritesScreen``, for the same reason.
    ///
    /// **What is adopted are its numbers and not its form** — exactly those that make sure a tile
    /// is the same size everywhere: ``TitleGrid/columnCount`` (three fixed columns, no adaptive
    /// count) and ``TitleGrid/tileWidth(at:wide:)``, which subtracts the space of the jump
    /// bar even when none is there. A measure of its own here would mean that the same film has two
    /// different sizes in the library and in downloads — and is fetched twice.
    ///
    /// **The jump bar itself is not here, and the rule for it is observed:**
    /// ``TitleGrid/barFrom`` demands twenty-four entries **and** more than two initial letters.
    /// Downloads are not a library with 4,211 titles but travel luggage; and they are not ordered
    /// alphabetically but chronologically — a letter bar would point into the void there.
    ///
    /// **The long press removes, and with more than one item it asks.** For a single file it stays
    /// with the previous path (context menu, no dialog); a poster with eight episodes behind it,
    /// however, is a bulk command in the shape of a single one — and bulk commands ask, as stated
    /// in ``Downloads/Cleanup``.
    private func posterGrid(_ groups: [DownloadGroup]) -> some View {
        LazyVGrid(
            columns: [GridItem](
                repeating: GridItem(.flexible(), spacing: MetricsBoard.phone.gutter),
                count: TitleGrid.columnCount(widthClass)),
            alignment: .leading, spacing: Metrics.rowGap
        ) {
            ForEach(groups) { group in
                Button {
                    tap(group)
                } label: {
                    PosterTile(content: group.tile, width: tileWidth)
                }
                .buttonStyle(.plain)
                // **The number belongs in the label** — ``PosterTile`` combines its children and then sets
                // one of its own from title and second line; "5 episodes" would drop out in the process. To
                // the eye that is the difference between one episode and five.
                .accessibilityLabel(Text(verbatim: group.spokenText))
                .contextMenu {
                    Button(role: .destructive) {
                        if group.count > 1 {
                            followUpQuestion = .group(group)
                        } else {
                            remove(group.representative.id)
                        }
                    } label: {
                        Label {
                            Text(app: "stock.remove")
                        } icon: {
                            Image(systemName: Glyph.remove.name)
                        }
                    }
                }
                // The same command for the screen reader — for it a long press is not a path, it occupies the
                // gesture itself.
                .accessibilityAction(named: Text(app: "stock.remove")) {
                    if group.count > 1 {
                        followUpQuestion = .group(group)
                    } else {
                        remove(group.representative.id)
                    }
                }
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.top, MetricsBoard.phone.gutter)
    }

    /// Where a poster leads.
    ///
    /// **For a group the series, for a single item the title itself** — the product requirement of
    /// 2026-09-09 in one line. If the callback for the series is missing, the poster leads to the first
    /// episode; the reasoning is at ``openSeries``.
    private func tap(_ group: DownloadGroup) {
        if let series = group.series, let openSeries {
            openSeries(series)
        } else {
            open(group.representative)
        }
    }

    // MARK: - Die Leiste unten

    /// **Only during selection, and then always visible.**
    ///
    /// It says in one sentence what the press costs: how many titles and how much space. A
    /// "Remove (3)" without gigabytes would make the viewer come back again to check whether it
    /// was enough — that is the rule from ``Downloads/Cleanup``.
    @ViewBuilder
    private var bulkBar: some View {
        if model.selection.pending {
            HStack(spacing: Metrics.targetSpacing) {
                Button {
                    model.selection.select(model.visible)
                } label: {
                    Text(app: "common.all")
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.text.color)
                        .frame(minHeight: Metrics.target)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                // **Not a dimmed button, but none at all.** As long as nothing is checked, there is nothing to
                // remove; a grey "Remove · 0" would be an invitation whose answer is the same every time.
                if let message = model.bulkText {
                    Button {
                        followUpQuestion = .selected
                    } label: {
                        Text(verbatim: message)
                            .font(TypeLevel.footer.font)
                            .foregroundStyle(ColorRole.brandLight.color)
                            .frame(minHeight: Metrics.target)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .background(.bar)
        }
    }

    private var storageRow: some View {
        Button(action: storage) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: model.headerCount)
                        .font(TypeLevel.header.font)
                        .foregroundStyle(ColorRole.text.color)
                    Spacer(minLength: Metrics.targetSpacing)
                    Text(verbatim: model.headerSpace)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
                StorageLegend(household: model.household)
            }
            .padding(MetricsBoard.phone.margin)
            .background(
                ColorRole.surface.color, in: RoundedRectangle(cornerRadius: MetricsBoard.phone.cardRadius)
            )
            .padding(.horizontal, MetricsBoard.phone.margin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, Metrics.targetSpacing)
    }

    private var filter: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Metrics.targetSpacing) {
                ForEach(DownloadsModel.Filter.allCases) { filter in
                    Button {
                        model.filter = filter
                    } label: {
                        // **The number sits on the chip.** A filter you have to tap to see whether it is empty is one
                        // too many.
                        Text(
                            verbatim:
                                "\(CaptionLabel.key(filter.key).readable) \(model.count(filter))"
                        )
                    }
                    .buttonStyle(.chip(active: model.filter == filter))
                }
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, Metrics.targetSpacing)
    }

    // MARK: - Leer

    /// **Information, not an error** — and you see the difference before you read: no frame, no
    /// surface, no warning triangle, no filled button.
    private var empty: some View {
        VStack(alignment: .leading, spacing: Metrics.targetSpacing) {
            Text(app: "stock.emptyTitle")
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.text.color)
            Text(app: "stock.emptyBody")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textQuiet.color)
            Button(action: toLibrary) { Text(app: "stock.toLibrary") }
                .buttonStyle(.chip(active: false))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.top, MetricsBoard.phone.gutter)
    }

    // MARK: - Ohne Netz

    @ViewBuilder
    private var offline: some View {
        if !isBandOnTop {
            HintRow(icon: Glyph.airplaneMode.name, title: "stock.offlineWorks")
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.bottom, Metrics.targetSpacing)
        }

        // **The same posters as in the full version, and here they count most.** Offline, the detail
        // page has no source to ask; what can be shown is exactly what was written down when the item
        // was queued. A second, poorer construction for the version this screen is built for would be
        // the wrong way round.
        //
        // **Finding from 2026-09-09, found during the rebuild and not requested:** Here stood
        // `menu: { remove(job.id) }` — the same mistake that was fixed in the full version on
        // the same day. A tap without a confirmation prompt threw away a finished download, and in the
        // very version in which you cannot fetch it again.
        //
        // **And the filter is explicitly left out.** Offline, the filter chips are not there; a filter
        // still set from earlier would then hide half of the downloads with no way to switch it off.
        nowPlaying(.everything)
        finishedItems(.everything)

        // **Named instead of left out.** Anyone who let the tabs silently disappear would make the
        // viewer search; anyone who left them in place would let the viewer run into them.
        Text(app: "stock.offlineMissing")
            .font(TypeLevel.label.font)
            .foregroundStyle(ColorRole.textQuiet.color)
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.top, MetricsBoard.phone.gutter)
    }
}
