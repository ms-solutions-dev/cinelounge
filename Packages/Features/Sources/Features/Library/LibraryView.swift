import Core
import DesignSystem
import Flows
import RatingsKit
import SwiftUI

/// A library as a grid, with sorting and jump marks.
public struct LibraryView: View {

    /// How many posters sit side by side.
    ///
    /// **Three, and that is calculated.** The derivation is in
    /// `LayoutBudgetTests` and is checked there as well: four did not fit next to
    /// the information column, and in SwiftUI content that is too wide overflows to
    /// both sides — it pushed itself under the sidebar, and "Skeblus deitseflaum Poblaplal"
    /// was missing its A.
    static let gridColumns = 3

    /// How many **wide** tiles sit side by side.
    ///
    /// Two, and that is calculated too: a 16:9 tile is 420 instead of 240 points
    /// wide; three of them no longer fit next to the information column. The
    /// calculation is in `LayoutBudgetTests` and is checked there.
    static let wideGridColumns = 2

    /// Abstand zwischen den Plakaten.
    static let gridSpacing: CGFloat = 44

    /// Spacing between the grid and the information column.
    static let columnGap: CGFloat = 40

    // MARK: - The height budget
    //
    // **These values are named because the height was once blown.** The
    // information column wanted around 1050 points, and after pill,
    // header and filter row the screen offered only about 700 — SwiftUI does not clip such a thing,
    // but lets the stack grow beyond the screen edge. The grid's scroll view
    // thereby got a visible area larger than the image, considered itself not
    // scrollable, and the second poster row was unreachable. `LayoutBudgetTests`
    // has recalculated the sum ever since; whoever changes a number here changes the
    // calculation there too.

    /// Top inset of the heading.
    static let headerTopPadding: CGFloat = 8

    /// What the heading occupies vertically: one line at title size including the inset.
    static var headerHeight: CGFloat {
        TypeLevel.lineHeight(zu: TypeLevel.title.points) + headerTopPadding
    }

    /// Top inset of the filter row.
    static let controlsTopPadding: CGFloat = 22

    /// Insets and gaps of the filter buttons. Tighter than before (26/14), because
    /// since the category button moved, the row carries all buttons and has to manage next to
    /// the information column — recalculated in the test suite.
    static let chipHorizontalPadding: CGFloat = 22
    static let chipVerticalPadding: CGFloat = 13
    static let chipSpacing: CGFloat = 12

    /// Height of a filter button: one label line including padding.
    static var chipHeight: CGFloat {
        TypeLevel.lineHeight(zu: TypeLevel.footer.points)
            + 2 * chipVerticalPadding
    }

    /// What the filter row occupies vertically.
    static var controlsHeight: CGFloat { chipHeight + controlsTopPadding }

    /// Limit for the category button's label, in characters. Genre names
    /// come from the server and can be arbitrarily long; without a limit a single
    /// name could push the row beyond the width. It is shortened with
    /// an ellipsis — the full name is in the expanded list.
    ///
    /// In characters and not in points, because a point measure is the wrong
    /// tool here: `frame(maxWidth:)` stretches a button to the measure instead of
    /// merely limiting it — "Anime" would then sit in a half-empty capsule.
    static let categoryLabelMaxCharacters = 12

    /// Shortens a category name to the limit.
    static func trimmedCategory(_ name: String) -> String {
        guard name.count > categoryLabelMaxCharacters else { return name }
        return name.prefix(categoryLabelMaxCharacters - 1) + "…"
    }

    /// Vertical padding of the grid. At the top it creates the room that the
    /// focus enlargement (``Tokens/Focus/cardScale``) needs at the edge.
    static let gridVerticalPadding: CGFloat = 30

    /// Top inset of the information column — ``DetailColumn/maxHeight`` calculates
    /// against it.
    static let columnTopPadding: CGFloat = 30

    @StateObject private var model: LibraryModel
    @FocusState private var focus: String?

    /// When the operator last did something themselves — the retrier then
    /// gives up (AP4 · K7, ``FocusRules/abandonsRetry(startedAt:lastInput:grace:)``).
    @State private var lastInputAt = Date.distantPast
    @State private var palette = AccentPalette.brand
    /// Whether the category list is expanded.
    @State private var isChoosingCategory = false
    /// Whether the library list at the title is expanded (AP89).
    @State private var isChoosingLibrary = false
    /// Whether the focus should land on the title once it stands — after a choice in the
    /// library list (AP89, A3). Read once from ``choice`` when this view is created.
    @State private var pendingTitleFocus = false
    @Namespace private var grid
    /// The grid's scroller — without it there is no jump to the start of a list
    /// whose first row has long since been torn down. See ``jumpToTop(_:)``.
    @State private var gridScroller: ScrollViewProxy?

    let onSelect: (MediaItem) -> Void

    /// The way out into the sidebar — or `nil` if the area runs its own
    /// stairs itself.
    ///
    /// **The library does, the provider library does not** — and that is what the
    /// finding of 2026-08-11 hung on: in VOD a press on Back between the
    /// posters closed the whole app. The reason was not that the stairs there would have been
    /// wrong, but that there were none: in the library they live in
    /// ``MainView`` above pill and navigation path, and here the menu key was attached to
    /// nothing.
    ///
    /// **`nil` therefore explicitly means "do not intercept here".** An interceptor
    /// that is always attached would consume the key in the library too — the
    /// pill would then no longer be reachable there (see ``exitCommand(isActive:action:)``).
    var onLeaveToSidebar: (() -> Void)?

    /// Which stairs this area leads out — see ``FocusRules/ExitStep``.
    ///
    /// The provider library has nothing below the section any more and takes the
    /// two-step ``FocusRules/vodLadder``; a portal leads arbitrarily deep and
    /// passes ``FocusRules/portalLadder``.
    var exitLadder: [FocusRules.ExitStep] = FocusRules.vodLadder

    /// Whether there is still a level below this view that has to be removed.
    ///
    /// Separate from the callback because the two are different things: **whether** a step
    /// is pending is a question for the navigation path and belongs in the testable
    /// rule (``pendingExitSteps(focus:ids:hasLevel:)``); **how** it is removed
    /// only the area that runs the path knows.
    var hasLevelBelow = false

    /// Removes a level. `nil` means: this area runs no levels.
    var onLeaveOneLevel: (() -> Void)?

    /// The library choice at the title (AP89) — `nil` with only one library of the kind,
    /// and everywhere outside the media tabs.
    var choice: TabLibraryChoice?

    public init(
        model: LibraryModel,
        onLeaveToSidebar: (() -> Void)? = nil,
        exitLadder: [FocusRules.ExitStep] = FocusRules.vodLadder,
        hasLevelBelow: Bool = false,
        onLeaveOneLevel: (() -> Void)? = nil,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        _model = StateObject(wrappedValue: model)
        self.onLeaveToSidebar = onLeaveToSidebar
        self.exitLadder = exitLadder
        self.hasLevelBelow = hasLevelBelow
        self.onLeaveOneLevel = onLeaveOneLevel
        self.onSelect = onSelect
    }

    /// A media tab with a library choice at its title (AP89).
    ///
    /// **Separate from the public initializer** because ``TabLibraryChoice`` belongs to the
    /// shell and stays internal; the provider library and the portals never pass one.
    init(
        model: LibraryModel,
        choice: TabLibraryChoice?,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        self.init(model: model, onSelect: onSelect)
        self.choice = choice
        _pendingTitleFocus = State(initialValue: choice?.landsOnTitle ?? false)
    }

    public var body: some View {
        // **`alignment: .top`, and the cut-off view hung on that.**
        //
        // A `ZStack` with no setting aligns to the center. If its content is taller than the
        // space, it is centered — and then something is missing **at the top and bottom**. With
        // films and series it is taller because the information column is on the right;
        // with home videos it is not, and that is exactly why the area was intact there. The
        // viewer's comparison was the hint that it hung on.
        //
        // The same error as once with the width: content that was too wide overflowed to
        // both sides, and it looked like an edge problem.
        ZStack(alignment: .top) {
            ColorRole.reason.color.ignoresSafeArea()

            switch model.state {
            // **All three contentless states need a focus anchor**, not only
            // the loading state: an empty library and an error message also hand the
            // focus over to the sidebar otherwise — and there it would then stay
            // permanently open. See ``FocusAnchor``.
            case .loading:
                VStack(spacing: 24) {
                    LoadingBand()
                    // As long as the CL-Server collects a sorted level (AP60) —
                    // the first time that can take minutes, and a silent band
                    // would then look like a hang.
                    if let done = model.preparedCount {
                        Text("library.sortingPrepared \(done)")
                            .font(.callout)
                            .foregroundStyle(ColorRole.textQuiet.color)
                    }
                }
                .focusAnchor("library-loading", focus: $focus)
            case .failed(let key):
                message(key, symbol: "exclamationmark.triangle.fill", tint: ColorRole.live.color)
                    .focusAnchor("library-failed", focus: $focus)
            case .empty:
                message("library.empty", symbol: "film.stack", tint: ColorRole.textQuiet.color)
                    .focusAnchor("library-empty", focus: $focus)
            case .ready(let items):
                content(items)
            }
        }
        // There used to be `.ignoresSafeArea(edges: [.bottom, .trailing])` here, and the line
        // had long done nothing: the app's outer frame already removes the
        // safe area completely (see ``MainView``), and inside
        // there is nothing left to remove. The bottom overscan inset is paid
        // explicitly instead — as padding under the grid and in the
        // upper limit of the information column, ``DetailColumn/maxHeight``.
        .environment(\.accentPalette, palette)
        .task { await model.load() }
        // Retry after a disruption as soon as the TV comes back —
        // see ``RetriesWhenAwake``.
        .retriesWhenAwake(isFailed: model.state.isFailed) { await model.load(force: true) }
        // **Pass the focus on from the anchor to the content.** The anchor disappears at
        // the moment the grid appears; whoever still holds it then holds an
        // element that no longer exists, and tvOS picks something itself again —
        // which would put the sidebar back in the race.
        // **Accent color and third-party ratings only once the focus is set.**
        //
        // Before, every tile had an observation of its own with an
        // unstructured `Task` that was not cancelled on the next step —
        // so while scrolling through, two requests per skipped title, which took the connections
        // away from the visible posters. See ``FocusFollowUp``.
        .whenFocusSettles(on: focus) { current in
            guard case .ready(let items) = model.state,
                let item = items.first(where: { $0.id == current })
            else { return }
            // **The background image first — before everything else.**
            //
            // It used to be at the very end here, behind accent color, ratings
            // and single request, and that is exactly how the downloads failed
            // (viewer finding 2026-08-08): those are three network paths, and whoever opens
            // after two seconds arrives before the image. It is also the
            // only one that needs **no** single request — its ID is
            // already in the list response. So here it costs nothing and brings
            // the biggest thing: the area that is the first thing noticed on opening.
            await DetailPrefetch.warmBackdrop(for: item, from: model.source)

            palette =
                await AccentExtractor.shared
                .palette(for: model.accentSourceURL(for: item)) ?? .brand
            await model.loadExternalRatings(for: item)
            await model.loadDetails(for: item)

            // And then the rest: cast and episodes. With the title **after**
            // ``loadDetails``, because the cast is not in the
            // list response but only in the single request.
            guard case .ready(let full) = model.state,
                let complete = full.first(where: { $0.id == current })
            else { return }
            await DetailPrefetch.warm(for: complete, from: model.source)
        }
        .onChange(of: model.state) { _, current in
            guard case .ready(let items) = current, let first = items.first else { return }
            // **Only when the anchor really held the focus.** `focus == nil` used to be
            // part of the condition here — but the local focus state is also
            // empty when the pill or sidebar holds the focus: its
            // focus lives in a different view. The consequence was the finding of the
            // test days: on the first area switch each time the focus jumped from
            // the pill down into the grid. Whoever holds the anchor is handed over;
            // whoever is elsewhere stays put.
            guard focus?.hasPrefix("library-") == true else { return }
            if takePendingTitleFocus() { return }
            focus = first.id
        }
        // **After a choice the focus belongs on the title** (A3), also when the chosen library
        // was already loaded and no loading state comes in between. First wait, then assign —
        // an immediate assignment is overwritten by the system's running focus assignment.
        .task {
            guard pendingTitleFocus, case .ready = model.state else { return }
            try? await Task.sleep(for: .milliseconds(120))
            _ = takePendingTitleFocus()
        }
        // **The stairs out, one step per press** (roadmap AP2). Attached
        // conditionally, because the library runs its own — the reasoning is
        // at ``onLeaveToSidebar``.
        .exitCommand(isActive: onLeaveToSidebar != nil, action: leaveOneStep)
        // **The occasion for the focus lines was missing here.** Without a key line
        // the straggler rule in `scripts/focus_trace.py` can by design never take effect —
        // in the material of 2026-08-23 there are 129 focus lines "Raster" against **zero**
        // key lines, and none of them says whether a press was behind it.
        //
        // **The body does nothing**, as with ``focusTrail(_:_:)``: an interceptor that
        // shifts the observed object is of no use here.
        .onMoveCommand { direction in
            // **The operator beats the retrier** (AP4 · K7): the mark
            // sits next to the trail line so both have the same source.
            lastInputAt = Date()
            Diagnostics.cursorKey("Raster", FocusTrail.name(direction))
        }
        // Only observes — see ``focusTrail(_:_:)``.
        .focusTrail("Raster", focus)
    }

    // MARK: - The way out

    /// Which stations of the stairs remain pending from a grid.
    ///
    /// **The start of the list is pending as long as the focus is on a different
    /// entry** — and only then. Whoever is already at the top has this step
    /// behind them; whoever is on the buttons above or on a jump mark
    /// is not in the grid at all, and putting them back down first would be a
    /// step inward on a press outward.
    ///
    /// The sidebar is always pending: it is the end of these stairs, not
    /// the end of the way — from there ``AppSidebar/Destination/stepOut``
    /// continues, and only on "Library" does the app close.
    /// - Parameter hasLevel: Whether there is still a level below this view.
    ///   **Only then is ``FocusRules/ExitStep/level`` pending** — at the
    ///   root level of a portal there is nothing to remove, and a press that
    ///   "shortens" the empty path looks like a dead key on the TV.
    static func pendingExitSteps(
        focus: String?, ids: [String], hasLevel: Bool = false
    ) -> Set<FocusRules.ExitStep> {
        var pending: Set<FocusRules.ExitStep> = [.sidebar]
        if let focus, focus != ids.first, ids.contains(focus) {
            pending.insert(.topOfList)
        }
        if hasLevel {
            pending.insert(.level)
        }
        return pending
    }

    /// One step out — the rule for it is in ``FocusRules/stepOut(along:pending:)``.
    private func leaveOneStep() {
        let ids = shownIDs
        switch FocusRules.stepOut(
            along: exitLadder,
            pending: Self.pendingExitSteps(
                focus: focus, ids: ids, hasLevel: hasLevelBelow && onLeaveOneLevel != nil)
        ) {
        case .topOfList:
            jumpToTop(ids)
        case .level:
            onLeaveOneLevel?()
        default:
            // Also the fallback: without content there is no start of the list to
            // jump to — then the next step applies immediately.
            onLeaveToSidebar?()
        }
    }

    /// The IDs of the shown titles, in the grid's order.
    ///
    /// Without the month grouping: it belongs to the home videos, and they run their
    /// stairs in ``MainView`` — only the provider library comes here, and it
    /// is a continuous grid.
    private var shownIDs: [String] {
        guard case .ready(let items) = model.state else { return [] }
        return model.visible(items).map(\.id)
    }

    /// Sets the focus on the first title — **scroll first, then grab, then
    /// grab again** (lesson from E20).
    ///
    /// The grid is built lazily: whoever is far down has long since lost the first row
    /// from memory. A focus on an entry that does not exist yet
    /// fizzles out without an error — and a press that does nothing looks like a broken key on
    /// the TV.
    private func jumpToTop(_ ids: [String]) {
        guard let first = ids.first else {
            onLeaveToSidebar?()
            return
        }
        gridScroller?.scrollTo(first, anchor: .top)
        focus = first

        let startedAt = Date()
        Task { @MainActor in
            // First wait, then check: a focus just written reads back
            // immediately, even if tvOS never accepted it.
            for _ in 1...5 {
                try? await Task.sleep(for: .milliseconds(50))
                if focus == first { return }
                // A press in this window used to be not swallowed
                // but actively undone — that looks worse
                // (AP4 · K7).
                if FocusRules.abandonsRetry(startedAt: startedAt, lastInput: lastInputAt) {
                    return
                }
                gridScroller?.scrollTo(first, anchor: .top)
                focus = first
            }
        }
    }

    private func content(_ items: [MediaItem]) -> some View {
        // **The category list comes from the unfiltered catalog, the grid from
        // the filtered one.** The other way round, after the first choice only this
        // one category would remain in the list, and one could not get out again.
        let categories = LibraryModel.categories(in: items)
        let shown = model.visible(items)

        return Group {
            // Home videos are grouped by months, everything else stays a
            // continuous grid. The reason is at `DateGroup`: with
            // `Video_017` one remembers the when, not the name.
            if model.usesDateGrouping {
                VStack(alignment: .leading, spacing: 0) {
                    header(count: shown.count)
                    controls(items, categories: categories)
                    groupedByMonth(shown)
                }
            } else {
                // **The information column sits next to the header AND the grid, not only next to
                // the grid.** That is half the answer to the blown
                // height budget: below heading and filter row only about 700 points were left
                // for the column, and its content could not be boiled down far enough for it to
                // say anything. Next to them it gets the full height under the pill — and its upper limit,
                // ``DetailColumn/maxHeight``, is calculated exactly from that.
                HStack(alignment: .top, spacing: Self.columnGap) {
                    VStack(alignment: .leading, spacing: 0) {
                        header(count: shown.count)
                        controls(items, categories: categories)
                        // **Also above the standing list** (AP60): after a press on
                        // "Rating" the grid stays in place until the sorted level is
                        // there — the first time minutes. Without this line it would be a
                        // button that nothing follows.
                        if let done = model.preparedCount {
                            Text("library.sortingPrepared \(done)")
                                .font(.callout)
                                .foregroundStyle(ColorRole.textQuiet.color)
                                .padding(.horizontal, MetricsBoard.tv.margin)
                        }
                        flatGrid(shown)
                    }

                    // The column on the right shows what is in focus — so one does not have to go into
                    // every title just to see what it is about.
                    DetailColumn(
                        item: focused(in: shown),
                        // **Deliberately the grid tile's measure and not the column's.**
                        // The column shows its poster smaller than the tile — a
                        // width of its own for it would mean: fetch the same file a second time,
                        // decode a second time, a second entry in the
                        // cache, and that for **every** title the focus
                        // moves over. This way tile and column share one entry.
                        posterURL: { model.posterURL(for: $0) },
                        external: model.externalRatings[focus ?? ""] ?? ExternalRatings(),
                        // Must be passed explicitly: the default of
                        // ``DetailColumn`` never delivers a trailer, and without this
                        // line the automatic start is entirely dead code — which shows
                        // only in that nothing happens at all.
                        trailerTarget: { await model.trailerTarget(for: $0) },
                        extras: { await model.extras(for: $0) }
                    )
                    .padding(.trailing, MetricsBoard.tv.margin)
                    .padding(.top, Self.columnTopPadding)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The list lies **over** the grid and does not push it away. If it took room,
        // everything would slide down on opening and back again on closing — one
        // would lose exactly the place where one wanted to see what the choice does.
        .overlay(alignment: .topLeading) {
            if isChoosingCategory {
                categoryPanel(categories)
                    .padding(.leading, MetricsBoard.tv.margin)
                    .padding(.top, Self.categoryPanelTop)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if isChoosingLibrary, let choice {
                libraryPanel(choice)
                    .padding(.leading, MetricsBoard.tv.margin)
                    .padding(.top, Self.libraryPanelTop)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isChoosingCategory)
        .animation(.easeOut(duration: 0.18), value: isChoosingLibrary)
    }

    /// How low the expanded list hangs: below the heading and the
    /// filter row in which its button sits.
    ///
    /// **Derived, not copied.** The value was once a fixed number,
    /// derived from the button's position at the time. When the content moved under the pill,
    /// the list suddenly hung above its own button — the derivation
    /// was no longer right, the number was. Now it calculates with the same quantities
    /// from which the button's position actually arises; the twelve points are the
    /// distance between the button's bottom edge and the list.
    static var categoryPanelTop: CGFloat { headerHeight + controlsHeight + 12 }

    private var categoryLabel: Text {
        // `verbatim`, because genres come from the server and cannot be translated:
        // "Anime" is called in every language what is entered there.
        if let category = model.category {
            return Text(verbatim: Self.trimmedCategory(category))
        }
        return Text(appKey: "filter.category")
    }

    static let categoryButtonID = "cat-open"

    static func categoryEntryID(_ name: String?) -> String {
        "catpick-" + (name ?? "all")
    }

    /// The expanded category list — see ``choicePanel(title:closeID:width:entriesHeight:isOpen:close:entries:)``.
    private func categoryPanel(_ categories: [String]) -> some View {
        choicePanel(
            title: Text(appKey: "filter.category"),
            closeID: "cat-close",
            width: Self.categoryPanelWidth,
            entriesHeight: Self.categoryListHeight(entries: categories.count + 1),
            isOpen: isChoosingCategory,
            close: closeCategoryPanel
        ) {
            categoryEntries(categories)
        }
    }

    /// The expanded list — **one board for the category and the library choice** (AP89).
    ///
    /// Built like the track picker in playback, and for the same reason: at the top
    /// is a button that is always there. If the list grows or shrinks, the
    /// focus does not lose its target — and tvOS does not put it at an arbitrary
    /// place.
    ///
    /// **Extracted and used twice** instead of copied: two lists that open the same way
    /// and close with the same key should not drift apart in a detail nobody looks for.
    private func choicePanel<Entries: View>(
        title: Text,
        closeID: String,
        width: CGFloat,
        entriesHeight: CGFloat,
        isOpen: Bool,
        close: @escaping () -> Void,
        @ViewBuilder entries: () -> Entries
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            closeButton(title: title, id: closeID, close: close)
                .padding(.bottom, 18)

            // **The board is as tall as its content, not as tall as its
            // upper limit.** A `ScrollView` takes the offered height regardless of the
            // content — with four categories an empty area of around 350 points
            // stayed under the last entry, and it looks like
            // a load that was aborted. The scroll view therefore only comes in when
            // the list needs it; below that the stack itself suffices.
            if entriesHeight <= Self.categoryPanelHeight {
                entries()
            } else {
                ScrollView {
                    entries()
                }
                .frame(maxHeight: Self.categoryPanelHeight)
            }
        }
        .padding(22)
        .frame(width: width, alignment: .leading)
        .background(ColorRole.surface.color, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(ColorRole.line.color, lineWidth: 2)
                // An overlay takes part in determining the focus target. Without this line
                // the outline covers the whole list: the focus would land on the first
                // entry and could not be moved on. This error has already occurred
                // six times in the project.
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.7), radius: 44, y: 20)
        .focusSection()
        // The menu key closes instead of going back one level. Without that, wanting to close leaves
        // the whole library.
        .exitCommand(isActive: isOpen, action: close)
    }

    /// The actual stack of entries — "All" first, then the categories.
    /// Standalone because, depending on length, it sits once bare and once in a
    /// scroll view; written out twice, the two variants
    /// would drift apart.
    private func categoryEntries(_ categories: [String]) -> some View {
        VStack(alignment: .leading, spacing: Self.categoryEntrySpacing) {
            categoryEntry(nil, title: Text(appKey: "common.all"))
            ForEach(categories, id: \.self) { name in
                categoryEntry(name, title: Text(verbatim: name))
            }
        }
    }

    static let categoryPanelWidth: CGFloat = 520
    /// Maximum height of the scroll view in the list. 540 instead of the earlier 620: the calculation in the
    /// test suite now counts honestly — with the pill above the view and the bottom
    /// overscan inset —, and it turned out that 620 ran off the bottom. An
    /// entry behind the screen edge does not look like a space error but
    /// like a category that does not exist.
    static let categoryPanelHeight: CGFloat = 540

    /// Height of a row of the category list and the gap between — named because
    /// the board calculates its height from them: from when the scroll view is needed follows
    /// from the content, not from an estimated number of entries.
    static let categoryEntryHeight: CGFloat = 62
    static let categoryEntrySpacing: CGFloat = 10

    /// What the stack of entries needs vertically — against this number the
    /// board decides whether to show the content bare or put it in the scroll view.
    static func categoryListHeight(entries: Int) -> CGFloat {
        CGFloat(entries) * categoryEntryHeight
            + CGFloat(max(entries - 1, 0)) * categoryEntrySpacing
    }

    /// The head of a board: what is chosen here, and "Done".
    private func closeButton(title: Text, id: String, close: @escaping () -> Void) -> some View {
        let isFocused = focus == id

        return Button(action: close) {
            HStack(spacing: 16) {
                title
                    .font(TypeLevel.header.font)
                Spacer(minLength: 20)
                Text(app: "common.done")
                    .font(TypeLevel.footer.font)
            }
            .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
            .padding(.horizontal, 24)
            .frame(height: 68)
            .background(
                isFocused ? ColorRole.text.color : ColorRole.text.color.opacity(0.12),
                in: Capsule()
            )
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .focusHighlight(isFocused, scale: Tokens.Focus.buttonScale, accent: Color(palette, .bright))
    }

    private func categoryEntry(_ name: String?, title: Text) -> some View {
        panelEntry(
            id: Self.categoryEntryID(name), title: title, isOn: model.category == name
        ) {
            model.choose(category: name)
            closeCategoryPanel()
        }
    }

    /// One row of a board: checkmark, name and — for libraries — the number of titles.
    private func panelEntry(
        id: String, title: Text, number: Int? = nil, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == id

        return Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: Glyph.override.name)
                    // The checkmark occupies its place even when it is not visible.
                    // Otherwise the label of every row shifts sideways on toggling, and the
                    // list jiggles.
                    .opacity(isOn ? 1 : 0)
                title
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let number {
                    Text(number, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(
                            isFocused
                                ? ColorRole.reason.color.opacity(0.7) : ColorRole.textQuiet.color)
                }
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
            .padding(.horizontal, 20)
            .frame(height: Self.categoryEntryHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isFocused ? ColorRole.text.color : Color.clear,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        // **The checkmark was also in the tree unseen**: it keeps its place via
        // `opacity(0)` so that the list does not jiggle on toggling — and
        // `opacity(0)` removes nothing from the screen reader. Every row began with
        // "Checkmark", the selected one like the unselected.
        .info(title, .chosen(isOn))
    }

    private func closeCategoryPanel() {
        isChoosingCategory = false
        focus = Self.categoryButtonID
    }

    // MARK: - The library choice (AP89)

    static let titleChoiceID = "lib-title"
    static let libraryCloseID = "lib-close"

    static func libraryEntryID(_ libraryID: String) -> String { "libpick-" + libraryID }

    /// How low the library list hangs: right below the title that opens it — it covers the
    /// filter row, as the category list covers the top of the grid.
    static var libraryPanelTop: CGFloat { headerHeight + 12 }

    /// Wider than the category board: the rows carry a number at the end.
    static let libraryPanelWidth: CGFloat = 620

    /// Height of the heading row ("Jellyfin") above the libraries.
    static let libraryHeadingHeight: CGFloat = 44

    /// What the library list needs vertically — the heading plus the rows.
    static func libraryListHeight(entries: Int) -> CGFloat {
        libraryHeadingHeight + categoryListHeight(entries: entries)
    }

    private func libraryPanel(_ choice: TabLibraryChoice) -> some View {
        choicePanel(
            title: Text(appKey: choice.titleKey),
            closeID: Self.libraryCloseID,
            width: Self.libraryPanelWidth,
            entriesHeight: Self.libraryListHeight(entries: choice.libraries.count),
            isOpen: isChoosingLibrary,
            close: closeLibraryPanel
        ) {
            VStack(alignment: .leading, spacing: Self.categoryEntrySpacing) {
                // **The same heading as in the phone's register** — the origin once above the
                // rows, not as a badge on every row.
                Text(app: "stock.mediaServer")
                    .font(TypeLevel.lowercased.font)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .padding(.horizontal, 20)
                    .frame(height: Self.libraryHeadingHeight, alignment: .bottomLeading)
                ForEach(choice.libraries) { library in
                    panelEntry(
                        id: Self.libraryEntryID(library.id),
                        title: Text(verbatim: library.name),
                        number: choice.counts[library.id],
                        isOn: library.id == choice.chosen
                    ) {
                        let changes = library.id != choice.chosen
                        closeLibraryPanel()
                        if changes { choice.select(library) }
                    }
                }
            }
        }
    }

    private func openLibraryPanel(_ choice: TabLibraryChoice) {
        isChoosingLibrary = true
        // The focus jumps to the library that is shown, not to the first row — the same rule
        // as for the category.
        focus = Self.libraryEntryID(choice.chosen)
    }

    /// Menu, "Done" or a choice — the focus goes back to the title each time.
    private func closeLibraryPanel() {
        isChoosingLibrary = false
        focus = Self.titleChoiceID
    }

    /// Moves the focus to the title if a choice asked for it — once.
    private func takePendingTitleFocus() -> Bool {
        guard pendingTitleFocus, choice != nil else { return false }
        pendingTitleFocus = false
        focus = Self.titleChoiceID
        return true
    }

    // MARK: - Continuous grid

    /// The grid — or, when the filter leaves nothing, a hint.
    @ViewBuilder
    private func flatGrid(_ items: [MediaItem]) -> some View {
        if items.isEmpty {
            // **The emptied-by-filter catalog needs a focus anchor too.** The three
            // contentless states at the start of the view have one; this case is
            // the fourth and was forgotten: `.ready` with a filter under which
            // nothing is listed would leave a grid without a single focusable element
            // behind — and tvOS would park the focus in the sidebar, which would then
            // open as if by itself. See ``FocusAnchor``.
            message("library.empty", symbol: "film.stack", tint: ColorRole.textQuiet.color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusAnchor("library-filtered", focus: $focus)
        } else {
            grid(items)
        }
    }

    /// A card's long-press menu: watched mark and favorites mark.
    ///
    /// **The short way for tidy-up actions in series.** Both actions used to exist
    /// only on the detail page — six to seven presses per title; the way
    /// the Apple TV app and Infuse do it, it is two with the long press. The
    /// labels are the same keys as on the detail page: an
    /// action that carries two names in two places reads as two actions.
    @ViewBuilder
    private func cardMenu(for item: MediaItem) -> some View {
        Button {
            Task { await model.toggleWatched(for: item) }
        } label: {
            Label(
                app: item.isWatched ? "detail.markUnwatched" : "common.markWatched",
                systemImage: item.isWatched ? "checkmark.circle.fill" : "checkmark.circle"
            )
        }
        Button {
            Task { await model.toggleFavorite(for: item) }
        } label: {
            Label(
                app: item.isFavorite ? "common.unfavorite" : "detail.favorite",
                systemImage: Glyph.favorite.pair.forItem(item.isFavorite)
            )
        }
        // Only for started titles (user request 2026-08-15): whoever has neither
        // progress nor can continue watching does not need the item —
        // and a menu that always shows everything reads as noise.
        if item.progress?.isResumable == true {
            Button {
                Task { await model.resetProgress(for: item) }
            } label: {
                Label(app: "common.resetProgress", systemImage: "arrow.counterclockwise")
            }
        }
    }

    /// The title the focus is on. Looked up via the ID and not
    /// carried along: this way nothing can drift apart when the list changes.
    private func focused(in items: [MediaItem]) -> MediaItem? {
        guard let focus else { return items.first }
        return items.first { $0.id == focus } ?? items.first
    }

    private func grid(_ items: [MediaItem]) -> some View {
        // **The format follows WHAT the entries are, not where they come from.**
        // The level decides for all tiles at once — the rule including
        // its reasoning is at ``MediaItem/prefersWideArtwork(in:)``. A source
        // whose images are 16:9 thereby gets a 16:9 frame instead of being cropped to
        // 2:3; everything unchecked stays portrait and
        // looks as before.
        let wide = MediaItem.prefersWideArtwork(in: items)
        let tile = wide ? MetricsBoard.tv.episode : MetricsBoard.tv.poster
        let columns = wide ? Self.wideGridColumns : Self.gridColumns

        return ScrollViewReader { scroller in
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .fixed(tile.width),
                            spacing: Self.gridSpacing
                        ),
                        count: columns
                    ),
                    alignment: .leading,
                    spacing: 52
                ) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            if wide {
                                EpisodeCard(
                                    item: item,
                                    // The requested width follows the
                                    // tile, not the poster measure — otherwise
                                    // a too-small image would end up on a larger area.
                                    imageURL: model.posterURL(
                                        for: item,
                                        width: ImageSizing.requestWidth(points: tile.width)
                                    ),
                                    isFocused: focus == item.id
                                )
                            } else {
                                PosterCard(
                                    item: item,
                                    imageURL: model.posterURL(for: item),
                                    isFocused: focus == item.id
                                )
                            }
                        }
                        .bareFocusableButton()
                        .focused($focus, equals: item.id)
                        .id(item.id)
                        .contextMenu { cardMenu(for: item) }
                        // **The next page when one of the last tiles appears**
                        // (AP60, since AP76 two rows earlier — ``Flows/LoadMore``). The
                        // grid is lazy: the last rows only come into being when the focus gets
                        // near them — which is exactly when the following page is needed.
                        .onAppear {
                            if LoadMore.applies(item, in: items) { Task { await model.loadMore() } }
                        }

                    }

                    // **Filler tiles for the last row.** tvOS finds the target
                    // of a movement geometrically: whoever stands in the second-to-last row
                    // on the right and presses down finds nothing if
                    // the last row has no entry there — the press
                    // fizzles out (on-device finding 2026-08-06). The invisible tiles
                    // complete the row; if the focus lands on one,
                    // ``grid(_:)`` passes it straight on to the last real
                    // entry.
                    let fillers = (columns - items.count % columns) % columns
                    ForEach(0..<fillers, id: \.self) { offset in
                        Color.clear
                            .frame(width: tile.width, height: tile.height)
                            .focusable()
                            .focused($focus, equals: "grid-filler-\(offset)")
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, MetricsBoard.tv.margin)
                .padding(.top, Self.gridVerticalPadding)
                // **More at the bottom than at the top, and that is calculated.** The app's
                // outer frame removes the safe area completely; the scroll view
                // therefore reaches the physical screen edge, and the last 60
                // points of it are cut off by some TVs. The padding ensures
                // that the last row at the end of scrolling stands **above** this
                // zone — including the allowance that the focus enlargement needs at the
                // bottom edge, because `scrollClipDisabled` deliberately no longer exists here
                // (see below).
                .padding(.bottom, TVMetrics.topMargin + Self.gridVerticalPadding)
            }
            // No `scrollClipDisabled`: it let the content draw beyond the bounds of the
            // scroll view — with films and series it thereby ran through the pill while
            // scrolling. With home videos it was not noticed, because the
            // month grouping takes a different path; that is exactly how it could be seen that
            // the correction had hit only one of two places.
            .overlay(alignment: .trailing) {
                initialsRail(items, scroller: scroller)
            }
            // **The scroller is grabbed on appearing, not on the key press.**
            // On the press it cannot be obtained — it lives in the body of this
            // scroll view, the interceptor hangs outside. The same lesson as with the
            // group list in the Live area (E20).
            .onAppear { gridScroller = scroller }
            // The resolution of the filler tiles: straight to the last real entry.
            .onChange(of: focus) { previous, current in
                if current?.hasPrefix("grid-filler-") == true {
                    // `guard` instead of assignment: without entries there would be no
                    // filler tiles, so the case is not reachable today —
                    // but `nil` would be the most expensive conceivable outcome (no
                    // more movement commands, menu key to the system), and the
                    // guarantee belongs here and not two functions further on.
                    // The fallback leaves the focus on the invisible
                    // filler tile; there is no better target in an
                    // empty grid, and staying put beats `nil`.
                    guard let last = items.last?.id else { return }
                    focus = last
                    return
                }
                // **From the pill downward left-aligned into the grid, not onto the
                // jump marks.** tvOS finds the target geometrically, and the bar at the
                // right edge is closer to the pill than the first tile — whoever holds
                // "Films" at the top and presses down landed on a letter
                // (on-device finding 2026-08-07). If the focus comes from outside (`previous ==
                // nil` means: pill or sidebar held it) straight onto a
                // jump mark, that was never a choice but geometry — then it belongs
                // on the first entry. Whoever goes from the grid to the right to the
                // bar, by contrast, has a `previous` and is left undisturbed.
                // Here too never onto `nil`: the jump mark bar exists only
                // from 24 entries, but that is 300 lines away and
                // cannot be read off at this line.
                if previous == nil, current?.hasPrefix("jump-") == true,
                    let first = items.first?.id
                {
                    focus = first
                }
            }
        }
    }

    // MARK: - Grouped by month

    private func groupedByMonth(_ items: [MediaItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 46) {
                ForEach(model.groups(items)) { group in
                    VStack(alignment: .leading, spacing: 18) {
                        monthHeading(group)

                        // Landscape format, not portrait: home videos have no
                        // poster but an image from the film itself — and that
                        // is wide. Framed upright it would be half cut off.
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(
                                    .fixed(MetricsBoard.tv.episode.width),
                                    spacing: 32
                                ),
                                count: 4
                            ),
                            alignment: .leading,
                            spacing: 38
                        ) {
                            ForEach(group.items) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        EpisodeCard(
                                            item: item,
                                            // Landscape format: the width follows
                                            // the card, not the poster measure.
                                            imageURL: model.posterURL(
                                                for: item,
                                                width: ImageSizing.requestWidth(
                                                    points: MetricsBoard.tv.episode.width
                                                )
                                            ),
                                            isFocused: focus == item.id
                                        )
                                        Text(verbatim: item.title)
                                            .font(TypeLevel.lowercased.font)
                                            .foregroundStyle(
                                                focus == item.id
                                                    ? ColorRole.text.color
                                                    : ColorRole.textMatt.color
                                            )
                                            .lineLimit(2)
                                            .frame(
                                                width: MetricsBoard.tv.episode.width,
                                                alignment: .leading
                                            )
                                    }
                                }
                                .bareFocusableButton()
                                .focused($focus, equals: item.id)
                                .contextMenu { cardMenu(for: item) }
                            }

                            // Filler tiles as in the continuous grid — per
                            // group, and it is passed on to the last
                            // entry **of this** group: from there the press continues
                            // to the next group.
                            let fillers = (4 - group.items.count % 4) % 4
                            ForEach(0..<fillers, id: \.self) { offset in
                                Color.clear
                                    .frame(
                                        width: MetricsBoard.tv.episode.width,
                                        height: MetricsBoard.tv.episode.height
                                    )
                                    .focusable()
                                    .focused($focus, equals: "month-filler-\(group.id)-\(offset)")
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, MetricsBoard.tv.margin)
            .padding(.top, Self.gridVerticalPadding)
            // The same padding as in the continuous grid, for the same reason: the
            // scroll view reaches the physical screen edge, and the last row
            // should stand above the overscan zone at the end of scrolling.
            .padding(.bottom, TVMetrics.topMargin + Self.gridVerticalPadding)
        }
        // The resolution of a month group's filler tiles: to the last real
        // entry of exactly this group.
        .onChange(of: focus) { _, current in
            guard let current, current.hasPrefix("month-filler-") else { return }
            let groupID =
                current
                .dropFirst("month-filler-".count)
                .split(separator: "-").dropLast().joined(separator: "-")
            let groups = model.groups(items)
            // **And never onto `nil`.** If the group disappears between display
            // and resolution — a reload, a changed filter —, no focus
            // at all would stay otherwise. This is not mere safeguarding
            // but a different answer than before: instead of nothing the
            // focus gets the last entry of the first group. That one certainly exists,
            // because a ``DateGroup`` without entries does not come into being.
            guard
                let target = groups.first(where: { $0.id == groupID })?.items.last?.id
                    ?? groups.first?.items.last?.id
            else { return }
            focus = target
        }
        // **No more `scrollClipDisabled`.** It was here so that enlarged posters
        // are not clipped at the edge — but for that the content drew beyond the
        // bounds of the scroll view and ran through the pill while scrolling.
        // The room for the enlargement is now provided by the padding inside.
    }

    /// The heading of a month group, such as "December 2023".
    ///
    /// The month name is not assembled by hand but formed by the system
    /// — otherwise it would be in German in every language.
    @ViewBuilder
    private func monthHeading(_ group: DateGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let month = group.month {
                Text(month, format: .dateTime.month(.wide).year())
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
            } else {
                Text(app: "library.undated")
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
            }

            Text(app: "library.itemCount \(group.items.count)")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
        }
    }

    /// The head of the page — the drawing itself is in ``LibraryHeader``.
    ///
    /// Extracted because the portal folder level needs the same head and
    /// drew it itself until 2026-08-28: with a different typeface, without count and
    /// inside the scroll view.
    @ViewBuilder
    private func header(count: Int) -> some View {
        if let choice {
            LibraryHeader(
                title: model.libraryName, count: count,
                choice: .init(id: Self.titleChoiceID, focus: $focus) { openLibraryPanel(choice) }
            )
            // **A section over the full width**, like the filter row below it: whoever stands on
            // "Category" at the right and presses up must reach the title on the left and not
            // jump past it into the pill. Only with a choice — the normal case keeps its
            // header untouched.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        } else {
            LibraryHeader(title: model.libraryName, count: count)
        }
    }

    /// The filter row: sorting, unwatched switch and the category button —
    /// **one** row, not two.
    ///
    /// The category button once sat in a row of its own below. That looked
    /// like a line break but was a second focus anchor on the way up: whoever wanted to go
    /// from the grid to the pill needed three presses instead of two. Merged,
    /// the way costs one intermediate step — the filter row —, and that is intended:
    /// it is a target one has to be able to hit. That all buttons fit side by side
    /// is recalculated by `LayoutBudgetTests`.
    ///
    /// **The category button itself instead of an open row with all categories:**
    /// a row with twenty buttons would lie permanently between sorting and grid.
    /// What the button shows is the state — "Category" as long as none is chosen,
    /// otherwise the name. A button that always looks the same conceals that the
    /// grid is filtered, and then one searches for a title that is there.
    private func controls(_ items: [MediaItem], categories: [String]) -> some View {
        HStack(spacing: Self.chipSpacing) {
            // **An order without a label appears in no row.** That is
            // `.natural` of the portal levels: the default in which no
            // button lights up — see ``LibraryModel/Sorting/titleKey``.
            ForEach(model.sortingChoices) { option in
                if let key = option.titleKey {
                    let isChosen = model.order.isExplicit && model.order.sorting == option
                    chip(
                        titleKey: key,
                        // **Only the explicit choice counts as set.** The
                        // default also sorts by title but is
                        // not a choice — a checkmark before it would claim the viewer
                        // had made it, and the third press would look as if
                        // it changed nothing.
                        isActive: isChosen,
                        id: "sort-" + option.id,
                        symbol: isChosen
                            ? (model.order.ascending ? "arrow.up" : "arrow.down") : nil
                    ) {
                        Task { await model.choose(option) }
                    }
                }
            }

            if !model.availableSlices.isEmpty || !categories.isEmpty {
                Divider()
                    .frame(height: 40)
                    .overlay(ColorRole.line.color)
                    .padding(.horizontal, 4)
            }

            ForEach(model.availableSlices) { slice in
                chip(
                    titleKey: slice.titleKey,
                    isActive: model.slice == slice,
                    id: "filter-" + slice.id
                ) {
                    Task { await model.select(slice: slice) }
                }
            }

            // Only when there is something to choose. For home videos that is never the case —
            // they carry no genres —, and a button behind which only "All" stands
            // would be a control that controls nothing.
            if !categories.isEmpty {
                chip(
                    title: categoryLabel,
                    isActive: model.category != nil,
                    id: Self.categoryButtonID
                ) {
                    isChoosingCategory = true
                    // The focus jumps to the currently valid entry and not to
                    // the first. Otherwise whoever only wants to look at what is
                    // set has to work their way there first.
                    focus = Self.categoryEntryID(model.category)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, MetricsBoard.tv.margin)
        .padding(.top, Self.controlsTopPadding)
        // **Over the full width and as a section of its own.** tvOS finds the target
        // of a movement geometrically: whoever stands on "A–Z" at the far left and presses up
        // finds nothing if the pill sits in the middle and does not overlap horizontally.
        // A section over the whole width overlaps with
        // it — the same consideration from which the pill itself already has one.
        .focusSection()
        // **From the pill downward left-aligned — without a visible intermediate step.**
        // Since the pill floats in the grids at its Home height, the
        // row is the first target under it, and tvOS chose the chip under the
        // pill's middle: "Category" instead of "A–Z" (simulator finding 2026-08-07). A
        // redirect after landing was visible — the focus hopped from right
        // to left (viewer finding). Hence an invisible interceptor over the
        // whole row width: it lies closest to the pill, catches the press and
        // passes it on to the left chip — on an element nobody
        // sees, nothing jumps. The same pattern as the scroll-back interceptor of the
        // head area, including its trap: the interceptor exists only as long as the
        // focus is outside OR it holds the focus itself — if it vanished in the
        // same pass in which it still holds the focus, tvOS would assign it
        // anew itself. Whoever goes up from the grid into the row hits the chips
        // directly (they are closer), and from the row upward the way
        // to the pill is free, because the interceptor does not exist then.
        .overlay(alignment: .top) {
            if focus == nil || focus == Self.controlsEntryID {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 10)
                    .focusable()
                    .focused($focus, equals: Self.controlsEntryID)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: focus) { _, current in
            guard current == Self.controlsEntryID,
                let first = model.sortingChoices.first
            else { return }
            focus = "sort-" + first.id
        }
    }

    /// The ID of the invisible entry interceptor of the filter row.
    static let controlsEntryID = "controls-entry"

    /// A button with a translated label.
    private func chip(
        titleKey: String,
        isActive: Bool,
        id: String,
        symbol: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        chip(
            title: Text(appKey: titleKey), isActive: isActive, id: id, symbol: symbol,
            action: action)
    }

    /// A button with finished text — for labels that come from the server and
    /// therefore have no translation key. If the label can be arbitrarily long,
    /// it should first go through ``trimmedCategory(_:)``.
    private func chip(
        title: Text,
        isActive: Bool,
        id: String,
        symbol: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isActive {
                    // **The arrow says the direction, the checkmark only the choice.**
                    // Without it nothing would be visible after the second press — and
                    // a reversal one cannot see looks like a
                    // button that does nothing.
                    Image(systemName: symbol ?? "checkmark")
                }
                title
                    .lineLimit(1)
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(chipForeground(isActive: isActive, id: id))
            .padding(.horizontal, Self.chipHorizontalPadding)
            .padding(.vertical, Self.chipVerticalPadding)
            .background(chipBackground(isActive: isActive, id: id), in: Capsule())
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        .focusHighlight(
            focus == id,
            scale: Tokens.Focus.buttonScale,
            accent: Color(palette, .bright)
        )
        // **The arrow is more than a choice here**: for sorting its
        // direction says which way round it sorts. For the screen reader what remains is
        // "selected" — the direction is in the label, and two statements
        // about the same thing drifted apart in the first rebuild.
        .info(title, .chosen(isActive))
    }

    private func chipForeground(isActive: Bool, id: String) -> Color {
        if focus == id { return ColorRole.reason.color }
        return isActive ? ColorRole.text.color : ColorRole.textMatt.color
    }

    private func chipBackground(isActive: Bool, id: String) -> Color {
        if focus == id { return ColorRole.text.color }
        return isActive ? Color(palette) : ColorRole.surface.color
    }

    /// The jump marks on the right edge.
    ///
    /// They appear only when there are enough titles — with a handful the
    /// bar would only be in the way.
    @ViewBuilder
    private func initialsRail(_ items: [MediaItem], scroller: ScrollViewProxy) -> some View {
        let initials = model.initials(for: items)

        if items.count >= 24, initials.count > 2 {
            // With many letters the bar contracts instead of running beyond the
            // screen edge: 26 marks at 40 points are 1230 — more than
            // the screen has, and letters were missing at the top and bottom
            // (finding 2026-08-07, section with 3737 titles).
            let compact = initials.count > 20
            VStack(spacing: compact ? 2 : 6) {
                ForEach(initials, id: \.self) { initial in
                    Button {
                        guard let target = model.firstItem(startingWith: initial, in: items) else {
                            return
                        }
                        withAnimation { scroller.scrollTo(target.id, anchor: .top) }
                        focus = target.id
                    } label: {
                        Text(verbatim: initial)
                            .font(TypeLevel.lowercased.font)
                            .fontWeight(.bold)
                            .foregroundStyle(
                                focus == "jump-" + initial
                                    ? ColorRole.reason.color : ColorRole.textMatt.color
                            )
                            .frame(width: compact ? 40 : 46, height: compact ? 27 : 40)
                            .background(
                                focus == "jump-" + initial ? ColorRole.text.color : .clear,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                    }
                    .bareFocusableButton()
                    .focused($focus, equals: "jump-" + initial)
                }
            }
            .padding(.vertical, compact ? 12 : 20)
            .padding(.trailing, 24)
            .background(ColorRole.reason.color.opacity(0.85), in: Capsule())
            .padding(.trailing, 20)
            .focusSection()
        }
    }

    private func message(_ key: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 22) {
            Image(systemName: symbol)
                .font(.system(size: 64))
                .foregroundStyle(tint)
            Text(appKey: key)
                .font(TypeLevel.header.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
        }
    }
}
